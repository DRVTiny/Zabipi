#!/usr/bin/perl
package Monitoring::Zabipi;
use utf8;
#binmode(STDOUT, ":utf8");  
use strict;
use warnings;
use Switch;
use Exporter qw(import);
our @EXPORT_OK=qw(new zbx zbx_last_err zbx_json_raw zbx_api_url);

use constant DEFAULT_ITEM_DELAY=>30;
use LWP::UserAgent;
use File::Temp;
use JSON qw( decode_json encode_json );

my %Config=(
  'default_params'=>{'item.create'=>{'delay'=>DEFAULT_ITEM_DELAY}}
);

my %ErrMsg;
my $JSONRaw;
my %SavedCreds;
my %cnfPar2cnfKey=('debug'=>{'type'=>'boolean','key'=>'flDebug'},
                   'wildcards'=>{'type'=>'boolean','key'=>'flSearchWildcardsEnabled'},
                   'timeout'=>{'type'=>'integer','key'=>'rqTimeout'},
                  );
my %rx=(
 'boolean'=>'^(?:y(?:es)?|true|ok|1|no?|false|0)$',
 'integer'=>'^[-+]?[0-9]+$',
 'float'=>'^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$',
);

sub new;
sub setErr;
sub zbx;
sub zbx_api_url;
sub zbx_last_err;
sub zbx_json_raw;
sub getDefaultMethodParams;
sub doItemNameExpansion;

sub new {
 return 0 unless @_;
 my ($myname,$apiUrl,$hlOtherPars)=@_;
 die "The second parameter must be a hash reference\n" if $hlOtherPars and ! (ref($hlOtherPars) eq 'HASH');
 $apiUrl="http://${apiUrl}/zabbix/api_jsonrpc.php" unless $apiUrl=~m%^https?://%;
 $Config{'apiUrl'}=$apiUrl;
 if (defined($hlOtherPars)) {
  unless (ref($hlOtherPars) eq 'HASH') {
   setErr('Last parameter of the "new" constructor (if present, and it is) must be a hash reference');
   return 0;
  }
  foreach my $cnfPar ( grep {defined $hlOtherPars->{$_}} keys %cnfPar2cnfKey ) {
   my ($v,$t,$k)=($hlOtherPars->{$cnfPar},@{$cnfPar2cnfKey{$cnfPar}}{'type','key'});
   unless ($v=~m/$rx{$t}/io) {
    setErr('Wrong parameter passed to the "new" constructor: '.$cnfPar.' must be '.$t);
    return 0
   }
   $Config{$k}=$t eq 'boolean'?($v=~m/y(?:es)?|true|1|ok/i?1:0):$v;
  }
  if (defined $hlOtherPars->{'debug_methods'}) {
   my $lstMethods2Dbg=$hlOtherPars->{'debug_methods'};
   if (! ref $lstMethods2Dbg) {
    $Config{'lstDebugMethods'}={ map { lc($_)=>1 } split /[,;]/,$lstMethods2Dbg };
   } elsif ((ref $lstMethods2Dbg eq 'HASH') && %{$lstMethods2Dbg} ) {
    $Config{'lstDebugMethods'}=$lstMethods2Dbg;
   } elsif ((ref $lstMethods2Dbg eq 'ARRAY') && @{$lstMethods2Dbg}) {
    $Config{'lstDebugMethods'}={ map { lc($_)=>1 } @{$lstMethods2Dbg} };
   } else {
    print STDERR 'ERROR: List of the methods to debug may be: hashref, arrayref, string';
    return 0;
   }
  }
 }
 return 1;
}

sub zbx_api_url {
 return $Config{'apiUrl'} || 0;
}

sub setErr {
 my $err_msg=scalar(shift);
 utf8::encode($err_msg);
 die $err_msg if scalar(shift);
 print STDERR $err_msg,"\n" if $Config{'flDebug'};
 $ErrMsg{'text'}=$err_msg;
 return 1;
}

sub zbx_last_err {
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

my %Cmd2APIMethod=('auth'=>'user.authenticate',
                   'logout'=>'user.logout',
                   'searchHostByName'=>'host.get',
                   'searchUserByName'=>'user.get',
                   'createItem'=>'item.create',
                   'getHostInterfaces'=>'hostinterface.get',
                   'createUser'=>'user.create');
my %MethodNeedWebLogin=(
                   'queue.get'=>1,
                   'graphimage.get'=>1,
                       );
# zbx internally doing some awful strange things such as:
# POST $url {"jsonrpc": "2.0","method":"user.authenticate","params":{"user":"Admin","password":"zabbix"},"auth": null,"id":0}
sub zbx  {
 my $what2do=shift;
 my ($req,$flExpandNames,@UnsetKeysInResult);
 my $ua = LWP::UserAgent->new;

 die "You must use 'new' constructor first and define some mandatory configuration parameters, such as URL pointing to server-side ZabbixAPI handler\n"
  unless $Config{'apiUrl'};
 if ( !($what2do eq 'auth' || $Config{'authToken'}) ) {
  setErr "You must be authorized first, use 'auth' before any other operations";
  return 0;
 }
 my $method=$what2do=~m/^[a-z]+?\.[a-z]+$/?$what2do:$Cmd2APIMethod{$what2do};
 unless ( $method ) {
  setErr "Unknown operation requested: $what2do";
  return 0;
 }
 if ( $MethodNeedWebLogin{$method} && ! $Config{'flWebLoginSuccess'} ) {
  (undef,$SavedCreds{'cookie_file'})=tempfile('XXXXXXXX',TMPDIR => 1);
  (my $ZabbixUrl=$Config{'apiUrl'})=~s%/[^/]+$%%;
  my $cmdLogin='curl -s -c '.$SavedCreds{'cookie_file'}." -d 'request=&name=$SavedCreds{'login'}&password=$SavedCreds{'passwd'}&autologin=1&enter=Sign+in' $ZabbixUrl/index.php' 2>&1";
  print STDERR 'Curl command to do Zabbix web login: '.$cmdLogin."\n";
  unless (my $maybErr=`$cmdLogin`) {
   setErr 'Method "'.$what2do.'" needs web login, but login failed because of web-authorization problem. Curl output follows: '."\n".$maybErr;
   return 0
  }
  $Config{'flWebLoginSuccess'}=1
 }
# Set default params ->
 @{$req}{'jsonrpc','params','method'}=('2.0',getDefaultMethodParams($method),$method);
# <- Set default params
 switch ($what2do) {
  case qr/^[a-z]+?\.[a-z]+$/ {
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
  };
  case 'auth' {
   if (!(@_ == 2 or @_ == 3)) {
    setErr 'You must specify (only) login and password for auth';
    return 0
   }
   @SavedCreds{'login','passwd'}=(shift,shift);
   $req->{'params'}={'user'=>$SavedCreds{'login'},'password'=>$SavedCreds{'passwd'}};
   $req->{'id'}=0;
  }; # <- auth
  case 'logout' {
   @{$req}{'auth','id','params'}=($Config{'authToken'},1,{});
  }; # <- logout
  case 'searchHostByName' {
   my $hostName=shift;
   $req->{'params'}{'output'}='extend';
   $req->{'params'}{'filter'}={'host'=>[$hostName]};
  }; # <- searchHostByName
  case 'searchUserByName' {
   $req->{'params'}{'filter'}={'alias'=>shift};
  }; # <- searchUserByName
  case 'getHostInterfaces' {
   my $hostID=shift;
   @{$req->{'params'}}{'output','hostids'}=('extend',$hostID);
  }; # <- getHostInterfaces
  case 'createUser' {
   my ($uid,$gid,$passwd)=@_; 
   if (!( $req->{'params'}{'usrgrps'}=[ zbx('searchGroup',{'status'=>0,'filter'=>{'name'=>$gid}})->[0] ] )) {
    setErr "Cant find group with name=$gid";
    return 0;
   }
   @{$req->{'params'}}{'passwd','alias'}=($passwd,$uid);
  }; # <- createUser
 } # <- switch ($what2do)
 @{$req}{'auth','id'}=($Config{'authToken'},1) if $Config{'authToken'};
 $req->{'params'}{'searchWildcardsEnabled'}=1 if (ref($req->{'params'}{'search'}) eq 'HASH') and $Config{'flSearchWildcardsEnabled'} and ! defined $req->{'params'}{'searchWildcardsEnabled'};
 # Redefine global config variables if it is specified as a 3-rd parameter to zbx() ->
 my %ConfigCopy=%Config;
 my $confPars=shift;
 $ConfigCopy{'flDebug'}=$ConfigCopy{'lstDebugMethods'}{$what2do} if defined($ConfigCopy{'lstDebugMethods'});
 @ConfigCopy{keys %{$confPars}}=values %{$confPars} if ref($confPars) eq 'HASH';
 # <-
 my $http_post = HTTP::Request->new(POST => $ConfigCopy{'apiUrl'});
 $http_post->header('content-type' => 'application/json');
 my $jsonrq=encode_json($req);
 print STDERR "JSON request:\n${jsonrq}\n" if $ConfigCopy{'flDebug'};
 $http_post->content($jsonrq);
 $ua->timeout($ConfigCopy{'rqTimeout'}) if defined $ConfigCopy{'rqTimeout'};
 $ua->show_progress(1) if $ConfigCopy{'flShowProgressBar'};
 my $ans=$ua->request($http_post);
 unless ( $ans->is_success ) {
  setErr 'HTTP POST request failed for some reason. Please double check, what you requested';
  return 0;
 }
 my $JSONAns=$ans->decoded_content;
 $JSONRaw=$JSONAns;
 print STDERR "Decoded content from POST:\n\t". $JSONAns . "\n"
  if $ConfigCopy{'flDebug'} and ! ($ConfigCopy{'flDbgResultAsListSize'} and (index($JSONAns,'"result":[')+1));
 return $JSONAns if $ConfigCopy{'flRetRawJSON'}; 
 $JSONAns = decode_json( $JSONAns );
 if ($JSONAns->{'error'}) {
  setErr('Error received from server in reply to JSON request: '.$JSONAns->{'error'}{'data'},$ConfigCopy{'flDieOnError'});
  return 0;
 }
 my $rslt=$JSONAns->{'result'};
 if ( $ConfigCopy{'flDebug'} and $ConfigCopy{'flDbgResultAsListSize'} ) {
  my $JSONAnsCopy;
  my @k=grep {$_ ne 'result'} keys %$JSONAns;
  @{$JSONAnsCopy}{@k}=@{$JSONAns}{@k};
  $JSONAnsCopy->{'result'}='List; Size='.scalar(@$rslt);
  print STDERR join("\n\t",'Decoded content from POST:',encode_json( $JSONAnsCopy ))."\n";
 }
 unless (ref($rslt) eq 'ARRAY'?scalar(@$rslt):defined($rslt)) {
  setErr 'Cant get result in JSON response for an unknown reason (no error was returned from Zabbix API)';
  return ref($rslt) eq 'ARRAY'?[]:0;
 }
 if ($what2do eq 'auth') {
  print STDERR "Got auth token=${rslt}\n" if $ConfigCopy{'flDebug'};
  $Config{'authToken'}=$rslt;
 } elsif ($what2do eq 'logout') {
  delete $Config{'authToken'};
 } elsif ($what2do =~ m/search[a-zA-Z]+ByName/) {
  return $rslt->[0];
 } 
 doItemNameExpansion($rslt,@UnsetKeysInResult) if $flExpandNames;
 return $rslt;
}

1;
