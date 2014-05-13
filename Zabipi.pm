#!/usr/bin/perl
package Monitoring::Zabipi;
use utf8;
#binmode(STDOUT, ":utf8");  
use strict;
use warnings;

use Exporter qw(import);
our @EXPORT_OK=qw(new zbx last_err zbx_json_raw);

use constant DEFAULT_ITEM_DELAY=>30;
use LWP::UserAgent;
use JSON qw( decode_json encode_json );

my %Config=(
  'default_params'=>{'item.create'=>{'delay'=>DEFAULT_ITEM_DELAY}}
);

my %ErrMsg;
my $JSONRaw;

sub new {
 return 1 unless @_; 
 my ($myname,$apiUrl,$hlOtherPars)=@_;
 die "The second parameter must be a hash reference\n" if $hlOtherPars and ! (ref($hlOtherPars) eq 'HASH');
 $apiUrl="http://${apiUrl}/zabbix/api_jsonrpc.php" unless $apiUrl=~m%^https?://%;
 $Config{'apiUrl'}=$apiUrl;
 $Config{'flDebug'}=$hlOtherPars->{'debug'}=~m/y(?:es)?|true|1/?1:0 if $hlOtherPars;
 return 1;
}

sub setErr {
 $ErrMsg{'text'}=join(' ',@_);
 print $ErrMsg{'text'}."\n" if $Config{'flDebug'};
 return 1;
}

sub last_err {
 return $ErrMsg{'text'} || 0;
}

sub zbx_json_raw {
 return $JSONRaw;
}

sub getDefaultMethodParams {
 my $method=shift;
 my ($mpar,$cpar)=@{$Config{'default_params'}}{($method,'common')};  
 return {} unless $mpar or $cpar;
 return { ref($cpar) eq 'HASH'?%{$cpar}:(),ref($mpar) eq 'HASH'?%{$mpar}:() };
}

sub doItemNameExpansion {
 my ($items,@unsetKeys)=@_;
 
 foreach my $item ( @{$items} ) {
  my ($itemName,$itemKey)=@{$item}{('name','key_')};
  my %h=map { $_=>1 } ($itemName=~m/\$([1-9])/g);
  unless ( %h ) {
   $item->{'name_expanded'}=$itemName;
   next;
  }
  for ($itemKey) {
   s%[^\[]+\[\s*%%;
   s%\]\s*$%%;
  }
  
  my @l=map { s/(?:^['"]|['"]$)//g; $_ } ($itemKey=~m/(?:^|,)\s*("[^"]*"|'[^']*'|[^'",]*)\s*(?=(?:,|$))/g);
  $itemName=~s/\$$_/$l[$_-1]/g foreach keys %h;
  $item->{'name_expanded'}=$itemName;
  delete @{$item}{@unsetKeys} if @unsetKeys;
 }
 return 1;
}

# zbx internally doing some awful strange things such as:
# POST $url {"jsonrpc": "2.0","method":"user.authenticate","params":{"user":"Admin","password":"zabbix"},"auth": null,"id":0}
sub zbx  {
 my $what2do=shift;
 my $req;
 my $ua = LWP::UserAgent->new;
 die "You must use 'new' constructor first and define some mandatory configuration parameters, such as URL pointing to server-side ZabbixAPI handler\n" unless $Config{'apiUrl'};
#==<auth>== 
 $req->{'jsonrpc'}='2.0';
 if ( !($what2do eq 'auth' || $Config{'authToken'}) ) {
  setErr "You must be authorized first, use 'auth' before any other commands";
  return 0;
 }
 my %Cmd2APIMethod=('auth'=>'user.authenticate',
                    'searchHostByName'=>'host.get',
                    'searchUserByName'=>'user.get',
                    'createItem'=>'item.create',
                    'getHostInterfaces'=>'hostinterface.get',
                    'createUser'=>'user.create');
 my $method=$what2do=~m/^[a-z]+?\.[a-z]+$/?$what2do:$Cmd2APIMethod{$what2do};
 unless ( $method ) {
  setErr "Unknown action requested: $what2do";
  return 0;
 }
 $req->{'params'}=getDefaultMethodParams($method);
 $req->{'method'}=$method;
 my $flExpandNames=undef;
 my @UnsetKeysInResult=();
# Set common params
 if ( $what2do =~ m/^[a-z]+?\.[a-z]+$/) {
  my $userParams=shift;
  @{$req->{'params'}}{keys %{$userParams}}=values %{$userParams} if ref($userParams) eq 'HASH';
  if ( ($what2do eq 'item.get') && $req->{'params'}{'expandNames'} ) {
   delete $req->{'params'}{'expandNames'};
   $flExpandNames=1;
   my $outcfg=$req->{'params'}{'output'};
   unless ($outcfg eq 'extend') {
    if (ref $outcfg eq 'ARRAY') {
     foreach my $mandAttr ('name','key_') {
      unless ( grep { $_ eq $mandAttr } @{$outcfg} ) {
       push @{$outcfg},$mandAttr;
       push @UnsetKeysInResult,$mandAttr;
      }
     }
    } else {
     $req->{'params'}{'output'}='extend';
    }
   }
  }
 } else {
  if ($what2do eq 'auth') {
   if (!(@_ == 2 or @_ == 3)) {
    setErr 'You must specify (only) login and password for auth';
    return 0;
   }
   $req->{'params'}={'user'=>shift,'password'=>shift};
   $req->{'id'}=0;
#==</auth>==
#==<searchHostByName>==
  } elsif ($what2do eq 'searchHostByName') {
   my $hostName=shift;
   $req->{'params'}{'output'}='extend';
   $req->{'params'}{'filter'}={'host'=>[$hostName]};
#==</searchHostByName>==
#==<searchUserByName>==
  } elsif ($what2do eq 'searchUserByName') {
   $req->{'params'}{'filter'}={'alias'=>shift};
#==</searchUserByName>==     
#==<getHostInterfaces>==
  } elsif ($what2do eq 'getHostInterfaces') {
   my $hostID=shift;
   @{$req->{'params'}}{('output','hostids')}=('extend',$hostID);
#==</getHostInterfaces>==  
#==<createUser>==
  } elsif ($what2do eq 'createUser') {
   my ($uid,$gid,$passwd)=@_; 
   if (!( $req->{'params'}{'usrgrps'}=[ zbx('searchGroup',{'status'=>0,'filter'=>{'name'=>$gid}})->[0] ] )) {
    setErr "Cant find group with name=$gid";
    return 0;
   }
   @{$req->{'params'}}{('passwd','alias')}=($passwd,$uid);
#==</createUser>==  
  }
 }
 @{$req}{('auth','id')}=($Config{'authToken'},1) if $Config{'authToken'};
 
 # Redefine global config variables if it is needed
 my %ConfigCopy=%Config;
 my $confPars=shift;
 @ConfigCopy{keys %{$confPars}}=values %{$confPars} if ref($confPars) eq 'HASH';
 
 my $http_post = HTTP::Request->new(POST => $ConfigCopy{'apiUrl'});
 $http_post->header('content-type' => 'application/json');
 my $jsonrq=encode_json($req);
 print "JSON request:\n${jsonrq}\n" if $ConfigCopy{'flDebug'};
 $http_post->content($jsonrq);
 my $ans=$ua->request($http_post);
 unless ( $ans->is_success ) {
  setErr 'HTTP POST request failed for some reason. Please double check, what you requested';
  return 0;
 }
 my $JSONAns=$ans->decoded_content;
 $JSONRaw=$JSONAns;
 print "Decoded content from POST:\n\t". $JSONAns . "\n" if $ConfigCopy{'flDebug'};
 return $JSONAns if $ConfigCopy{'flRetRawJSON'};
 $JSONAns = decode_json( $JSONAns );
 if ($JSONAns->{'error'}) {
  setErr 'Error received from server in reply to JSON request: '.$JSONAns->{'error'}{'data'};
  return 0;
 }
 my $rslt=$JSONAns->{'result'};
 unless ($rslt) {
  setErr 'Cant get result in JSON response for unknown reason (no error was returned from Zabbix API)';
  return 0;
 }
 if ($what2do eq 'auth') {
  print "Got auth token=${rslt}\n" if $ConfigCopy{'flDebug'};
  $Config{'authToken'}=$rslt;
 } elsif ($what2do =~ m/search[a-zA-Z]+ByName/) {
  return $rslt->[0];
 } 
 doItemNameExpansion($rslt,@UnsetKeysInResult) if $flExpandNames;
 return $rslt;
}

1;
