#!/usr/bin/perl -w
#
# ==========================================================================
#
# ZoneMinder ONVIF Event Watcher Script
# Copyright (C) Jan M. Hochstein
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
#
# ==========================================================================
#
# This module contains the implementation of the ONVIF event watcher
#

## SETUP:
##    chmod g+rw /dev/shm/zm*
##    chgrp users /dev/shm/zm*
##    systemctl stop iptables

## DEBUG:
##    hexdump -x -s 0 -n 600 /dev/shm/zm.mmap.1
##    rm -rf /srv/www/html/zm/events/[...]
##

use strict;
use bytes;

use Carp;
use Data::Dump qw( dump );

use DBI;
use Getopt::Long qw(:config no_auto_abbrev no_ignore_case bundling);
use IO::Select;
use POSIX qw( EINTR );
use Time::HiRes qw( usleep );

use SOAP::Lite; # +trace;
use SOAP::Transport::HTTP;

use ZoneMinder;

require ONVIF::Client;

require WSNotification::Interfaces::WSBaseNotificationSender::NotificationProducerPort;
require WSNotification::Interfaces::WSBaseNotificationSender::SubscriptionManagerPort;
require WSNotification::Types::TopicExpressionType;

# ========================================================================
# Constants

# in seconds
use constant SUBSCRIPTION_RENEW_INTERVAL => 60;  #3600;
use constant SUBSCRIPTION_RENEW_EARLY => 5; # 60;
use constant MONITOR_RELOAD_INTERVAL => 3600;

# ========================================================================
# Globals

my $verbose = 0;
my $daemon_pid;

my $monitor_reload_time = 0;

# this does not work on all architectures
my @EXTRA_SOCK_OPTS = (
    'ReuseAddr' => '1',
    'ReusePort' => '1',
#    'Blocking'  => '0',
);


# =========================================================================
# signal handling

sub handler { # 1st argument is signal name
  my($sig) = @_;
  print "Caught a SIG$sig -- shutting down\n";
  confess();
  if(defined $daemon_pid){
    kill($daemon_pid);
  }
  exit(0);
}

$SIG{'INT'} = \&handler;
$SIG{'HUP'} = \&handler;
$SIG{'QUIT'} = \&handler;
$SIG{'TERM'} = \&handler;
$SIG{__DIE__} = \&handler;

# =========================================================================
# Debug

use Data::Hexdumper qw(hexdump);
#use Devel::Peek;

sub dump_mapped
{
  my ($monitor) = @_;
  
  if(!zmMemVerify($monitor)) {
    print "Error: Mapped memory not accessible\n";
  }
  my $mmap = $monitor->{MMap};
  print "Size: " . $ZoneMinder::Memory::mem_size ."\n";
  printf("Mapped at %x\n", $monitor->{MMapAddr}); 
#  Dump($mmap);
  if($mmap && $$mmap )
  {
    print hexdump(
      data           => $$mmap, # what to dump
      output_format  => '  %4a : %S %S %S %S %S %S %S %S         : %d',
#      start_position => 336,   # start at this offset ...
      end_position   => 400    # ... and end at this offset
    );
  }
}

#push @EXPORT, qw(dump_mapped);

# =========================================================================
# internal methods

sub xs_duration
{
  use integer;
  my ($seconds) = @_;
  my $s = $seconds % 60;
  $seconds /= 60;
  my $m = $seconds % 60;
  $seconds /= 60;
  my $h = $seconds % 24;
  $seconds /= 24;
  my $d = $seconds;
  my $str;
  if($d > 0) {
    $str = "P". $d;
  }
  else {
    $str = "P";
  }
  $str = $str . "T";
  if($h > 0) {
    $str = $str . $h . "H";
  }
  if($m > 0) {
    $str = $str . $m . "M";
  }
  if($s > 0) {
    $str = $str . $s . "S";
  }
  return $str;
}

# =========================================================================
### ZoneMinder integration

## make this a singleton ?
{
  package _ZoneMinder;
  
  use strict;
  use bytes;
  
  use base qw(Class::Std::Fast);

  use DBI;
  use Encode qw(decode encode);
  use Time::HiRes qw( usleep );
  use ZoneMinder;


#  my %monitors = ();
  my $dbh;
  my %monitors_of; #   :ATTR(:name<monitors> :default<{}>);


  sub init
  {
    $dbh = zmDbConnect();
  }

  sub monitors
  {
    my ($self) = @_;
    return $monitors_of{ident $self}?%{ $monitors_of{ident $self} }:undef;
  }

  sub set_monitors
  {
    my ($self, %monitors_par) = @_;
    $monitors_of{ident $self} = \%monitors_par;
  }

## TODO: remember to refresh this in all threads (daemon is forked)
  sub loadMonitors
  {
    my ($self) = @_;
	  Debug( "Loading monitors\n" );
	  $monitor_reload_time = time();

	  my %new_monitors = ();

  #	my $sql = "select * from Monitors where find_in_set( Function, 'Modect,Mocord,Nodect,ExtDect' )>0 and ConfigType='ONVIF'";
	  my $sql = "select * from Monitors where ConfigType='ONVIF'";
	  my $sth = $dbh->prepare_cached( $sql ) or Fatal( "Can't prepare '$sql': ".$dbh->errstr() );
	  my $res = $sth->execute() or Fatal( "Can't execute: ".$sth->errstr() );
	  while( my $monitor = $sth->fetchrow_hashref() )
	  {
		  if ( !zmMemVerify( $monitor ) )  { # Check shared memory ok
        zmMemInvalidate( $monitor );
        next if ( !zmMemVerify( $monitor ) );
      }

#$monitor->{MMapAddr} = undef;
#memAttach( $monitor, 896 );
#next if ( !zmMemVerify( $monitor ) );
#main::dump_mapped($monitor);
    
      print "URL: " .$monitor->{ConfigURL}. "\n";

      ## set up ONVIF client for monitor
      next if( ! $monitor->{ConfigURL} );

      my $soap_version;
      if($monitor->{ConfigOptions} =~ /SOAP1([12])/) {
        $soap_version = "1.$1";
      }
      else {
        $soap_version = "1.1";
      }
      my $client = ONVIF::Client->new( { 
        'url_svc_device' => $monitor->{ConfigURL}, 
        'soap_version' => $soap_version } );

      if($monitor->{User}) {
        $client->set_credentials($monitor->{User}, $monitor->{Pass}, 0);
      }

      $client->create_services();
      $monitor->{onvif_client} = $client;

		  $new_monitors{$monitor->{Id}} = $monitor;
	  }
	  $self->set_monitors(%new_monitors);
  }

  sub freeMonitors
  {
    my ($self) = @_;
    my %monitors = $self->monitors();
	  foreach my $monitor ( values(%monitors) )
    {
      # Free up any used memory handle
      zmMemInvalidate( $monitor );
    }
  }

  sub eventOn
  {
    my ($self, $monitorId, $score, $cause, $text, $showtext) = @_;
  #	Info( "Trigger '$trigger'\n" );
    print "On: $monitorId, $score, $cause, $text, $showtext\n";
    my %monitors = $self->monitors();
    my $monitor = $monitors{$monitorId};
    # encode() ensures that no utf-8 is written to mmap'ed memory.
    zmTriggerEventOn( $monitor, $score, encode("utf-8", $cause), encode("utf-8", $text) );
    zmTriggerShowtext( $monitor, encode("utf-8", $showtext) ) if defined($showtext);
#    main::dump_mapped($monitor);
  }

  sub eventOff
  {
    my ($self, $monitorId, $score, $cause, $text, $showtext) = @_;
    print "Off: $monitorId, $score, $cause, $text, $showtext\n";
    my %monitors = $self->monitors();
    my $monitor = $monitors{$monitorId};
    my $last_event = zmGetLastEvent( $monitor );
    zmTriggerEventOff( $monitor );
    # encode() ensures that no utf-8 is written to mmap'ed memory.
	  zmTriggerShowtext( $monitor, encode("utf-8", $showtext) ) if defined($showtext);
  #	Info( "Trigger '$trigger'\n" );
    # Wait til it's finished
    while( zmInAlarm( $monitor ) && ($last_event == zmGetLastEvent( $monitor )) )
    {
       # Tenth of a second
       usleep( 100000 );
    }
	  zmTriggerEventCancel( $monitor );
#    main::dump_mapped($monitor);
  }

}
# =========================================================================
### (experimental) send email

sub send_picture_email
{
  
#  'ffmpeg -i "rtsp://admin:admin123@192.168.0.70:554/Streaming/Channels/1?transportmode=mcast&profile=Profile_1" -y -frames 1 -vf scale=1024:-1 /tmp/pic2.jpg'
}

# =========================================================================
### Consumer for Notify messages

$SOAP::Constants::DO_NOT_CHECK_MUSTUNDERSTAND = 1;

## make this a singleton ?
{
  package _Consumer;
  use strict;
  use bytes;
  use base qw(Class::Std::Fast SOAP::Server::Parameters);
 
  my $zm;

  sub BUILD {
    my ($self, $ident, $arg_ref) = @_;
#    $zm_of{$ident} = check_name( $arg_ref->{zm} );
    $zm = $arg_ref->{zm};
  }

  #
  # called on http://docs.oasis-open.org/wsn/bw-2/NotificationConsumer/Notify
  #
  sub Notify
  {
    my ($self, $unknown, $som) = @_;
    print "### Notify " . "\n";
    my $req = $som->context->request;
#    Data::Dump::dump($req);
    my $id = 0;
    if($req->uri->path =~ m|/ref_(.*)/|) {
      $id = $1;
    }
    else {
      print "Unknown URL ". $req->uri->path . "\n";
      return ( );
    }
#    Data::Dump::dump($som);
    my $action = $som->valueof("/Envelope/Header/Action");
    print "  Action = ". $action ."\n";
    my $msg = $som->match("/Envelope/Body/Notify/NotificationMessage");
    my $topic = $msg->valueof("Topic");
    my $msg2  = $msg->match("Message/Message");
#    Data::Dump::dump($msg2->current());
    my $time = $msg2->dataof()->attr->{'UtcTime'};
    
    my (%source, %data);
    foreach my $item ($msg2->dataof('Source/SimpleItem')) {
      $source{$item->attr->{Name}} = $item->attr->{Value};
#      print $item->attr->{Name} ."=>". $item->attr->{Value} ."\n";
    }
    foreach my $item ($msg2->dataof('Data/SimpleItem')) {
      $data{$item->attr->{Name}} = $item->attr->{Value};
    }
    print "Ref=$id, Topic=$topic, $time, Rule=$source{Rule}, isMotion=$data{IsMotion}\n";
    if(lc($data{IsMotion}) eq "true") {
      $zm->eventOn($id, 100, $source{Rule}, $time);
    }
    elsif(lc($data{IsMotion}) eq "false") {
      $zm->eventOff($id, 100, $source{Rule}, $time);
    }
    return ( );  # @results
  }
}

# =========================================================================

sub daemon_main
{
  my ($daemon) = @_;
  
#  $daemon->handle();

# improve responsiveness with multiple clients (cameras)
  my $d = $daemon->{_daemon};
  my $select = IO::Select->new();
  $select->add($d);
  while ($select->count()) {
    my @ready = $select->can_read();  # blocks
    foreach my $connection (@ready) {
      if ($connection == $d) {
        # on the daemon accept and add the connection 
        my $client = $connection->accept();
        $select->add($client);
      }
      else {
        # it's a client connection
        my $request = $connection->get_request();
        if ($request) {
          # process the request (taken from SOAP::Transport::HTTP::Daemon->handle() )
          $daemon->request($request);
          $daemon->SOAP::Transport::HTTP::Server::handle();
          eval {
              local $SIG{PIPE} = sub {die "SIGPIPE"};
              $connection->send_response( $daemon->response );
          };
          if ($@ && $@ !~ /^SIGPIPE/) {
              die $@;
          }
        }
        else {
          # connection was closed by the client
          $select->remove($connection);
          $connection->close();  # is this necessary?
        }
      }
    }
  }
}

sub start_daemon
{
  my ($localip, $localport, $zm) = @_;

=comment
    ### deserializer
    my $event_svc = $client->get_endpoint('events');
    my $deserializer = $event_svc->get_deserializer();

    if(! $deserializer) {
      $deserializer = SOAP::WSDL::Factory::Deserializer->get_deserializer({
        soap_version => $event_svc->get_soap_version(),
        %{ $event_svc->get_deserializer_args() },
      });
    }
    # set class resolver if serializer supports it
    $deserializer->set_class_resolver( $event_svc->get_class_resolver() )
        if ( $deserializer->can('set_class_resolver') );
=cut
    ### daemon
    my $daemon = SOAP::Transport::HTTP::Daemon->new(
        'LocalAddr' => $localip, 
        'LocalPort' => $localport,
#        'deserializer' => $deserializer,
        @EXTRA_SOCK_OPTS
    );

    ## handling

    # we only handle one method
    $daemon->on_dispatch( sub {
      return ( "http://docs.oasis-open.org/wsn/bw-2/NotificationConsumer", "Notify" );
    });
  
 	$daemon_pid = fork();
  die "fork() failed: $!" unless defined $daemon_pid;
  if ($daemon_pid) {
    # $zm is copied and the mmap'ed regions still exist
    my $consumer = _Consumer->new({'zm' => $zm});
    $daemon->dispatch_with({
#       "http://docs.oasis-open.org/wsn/bw-2" => $consumer,
       "http://docs.oasis-open.org/wsn/bw-2/NotificationConsumer"  => $consumer,
    });
    daemon_main($daemon);
  }
  else {
    return $daemon;
  }
}

require WSNotification::Elements::Subscribe;
require WSNotification::Types::EndpointReferenceType;
#require WSNotification::Types::ReferenceParametersType;
#require WSNotification::Elements::Metadata;
require WSNotification::Types::FilterType;
require WSNotification::Elements::TopicExpression;
require WSNotification::Elements::MessageContent;
require WSNotification::Types::AbsoluteOrRelativeTimeType;
require WSNotification::Types::AttributedURIType;


sub subscribe
{
  my ($client, $localaddr, $topic_str, $duration, $ref_id) = @_;

# for debugging:  
#  $client->get_endpoint('events')->no_dispatch(1);

  my $result = $client->get_endpoint('events')->Subscribe( {
    ConsumerReference =>  { # WSNotification::Types::EndpointReferenceType
      Address =>  { value => 'http://' . $localaddr . '/ref_'. $ref_id . '/' },
#      ReferenceParameters =>  { # WSNotification::Types::ReferenceParametersType
#      },
#      Metadata =>  { # WSNotification::Types::MetadataType
#      },
    },
    Filter =>  { # WSNotification::Types::FilterType
       TopicExpression => { # WSNotification::Types::TopicExpressionType
         xmlattr => { 
           Dialect => "http://www.onvif.org/ver10/tev/topicExpression/ConcreteSet",
        },
        value => $topic_str,
      },
#      MessageContent =>  { # WSNotification::Types::QueryExpressionType
#      },      
    },
    InitialTerminationTime => xs_duration($duration), # AbsoluteOrRelativeTimeType
#    SubscriptionPolicy =>  {
#    },
  },,
 );

  die $result if not $result;
# print $result . "\n";

### build Subscription Manager
  my $submgr_addr = $result->get_SubscriptionReference()->get_Address()->get_value();
  print "Subscription Manager at $submgr_addr\n";
    
  my $serializer = $client->service('device', 'ep')->get_serializer();
  
  my $submgr_svc = WSNotification::Interfaces::WSBaseNotificationSender::SubscriptionManagerPort->new({
    serializer => $serializer,
    proxy => $submgr_addr,
  });

  return $submgr_svc;
}

sub unsubscribe
{
  my ($submgr_svc) = @_;
  
  $submgr_svc->Unsubscribe( { },, );
}

sub renew
{
  my ($submgr_svc, $duration) = @_;
  
  my $result = $submgr_svc->Renew( { 
      TerminationTime => xs_duration($duration), # AbsoluteOrRelativeTimeType
    },, 
  );
  die $result if not $result;
}


sub events
{
  my ($localip, $localport) = @_;

  my $zm = _ZoneMinder->new();
  $zm->init();
  $zm->loadMonitors();  # call before fork()

  my %monitors = $zm->monitors();
  my $monitor_count = scalar keys(%monitors);
  if($monitor_count == 0) {
    print("No active ONVIF monitors found. Exiting\n");
    return;
  }
  else {
    Debug( "Found $monitor_count active ONVIF monitors\n" );
  }
  
  Info( "ONVIF Trigger daemon starting\n" );

  if(!defined $localip) {
    $localip = '192.168.0.2';
    $localport = '0';
  }

    # re-use local address/port
#   @LWP::Protocol::http::EXTRA_SOCK_OPTS =
    *LWP::Protocol::http::_extra_sock_opts = sub 
    {
#      print "### extra_sock_opts ########################################\n";
      @EXTRA_SOCK_OPTS;
    };

#*LWP::Protocol::http::_check_sock = sub 
#{
#    my($self, $req, $sock) = @_;
#    print "### check_sock ########################################\n";
#    dump($sock);
#};

    my $daemon = start_daemon($localip, $localport, $zm);
    my $port = $daemon->url;
    $port =~ s|^.*:||;
    $port =~ s|/.*$||;
    my $localaddr = $localip . ':' . $port;
    
    print "Daemon uses local address " . $localaddr . "\n";

    # This value is passed as the LocalAddr argument to IO::Socket::INET.
    my $transport = SOAP::Transport::HTTP::Client->new( 
#      'local_address' => $localaddr );     ## REUSE port
       'local_address' => $localip );    
  
    foreach my $monitor (values(%monitors)) {
    
      my $client = $monitor->{onvif_client};
      my $event_svc = $client->get_endpoint('events');
      $event_svc->set_transport($transport);
#      print "Sending from local address " . 
#        $event_svc->get_transport()->local_address . "\n";

      my $submgr_svc = subscribe(
            $client, $localaddr, 'tns1:RuleEngine//.', 
            SUBSCRIPTION_RENEW_INTERVAL, $monitor->{Id});
    
      if(!$submgr_svc) {
        print "Subscription failed\n";
        next;
      }
    
      $monitor->{submgr_svc} = $submgr_svc;
    }
    
    while(1) {
      print "Sleeping for " . (SUBSCRIPTION_RENEW_INTERVAL - SUBSCRIPTION_RENEW_EARLY) . " seconds\n";
      sleep(SUBSCRIPTION_RENEW_INTERVAL - SUBSCRIPTION_RENEW_EARLY);
      print "Renewal\n";
      my %monitors = $zm->monitors();
      foreach my $monitor (values(%monitors)) {
        if(defined $monitor->{submgr_svc}) {
          renew($monitor->{submgr_svc}, SUBSCRIPTION_RENEW_INTERVAL + SUBSCRIPTION_RENEW_EARLY);
        }
      }
    };
    
    Info( "ONVIF Trigger daemon exited\n" );

    %monitors = $zm->monitors();
    foreach my $monitor (values(%monitors)) {
      if(defined $monitor->{submgr_svc}) {
         unsubscribe($monitor->{submgr_svc});
      }
    }
}

# ========================================================================
# options processing

sub HELP_MESSAGE
{
  my ($fh, $pkg, $ver, $opts) = @_;
  print $fh "Usage: " . __FILE__ . " <parameters>\n";
  print $fh  <<EOF
  Parameters:
    -v              - increase verbosity
    -l|local-addr   - listen on address (host[:port])
EOF
}

# ========================================================================
# MAIN
  
my ($localaddr, $localip, $localport);

logInit();
logSetSignal();

if(!GetOptions(
      'local-addr|l=s'    => \$localaddr,
      'verbose|v=s'       => \$verbose,
      )) {
  HELP_MESSAGE(\*STDOUT);
  exit(1);
}

if(defined $localaddr) {
  if($localaddr =~ /(.*):(.*)/)
  {
    ($localip, $localport) = ($1, $2);
  }
  else {
    $localip = $localaddr;
    $localport = '0';
  }
}
{
  events($localip, $localport);
}
