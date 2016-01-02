#!/usr/bin/perl -CDA
use strict;
use utf8;
use constant {
     SETENV_FILE=>'setenv.conf',
     TIMEZONE=>'MSK',
};
my %SETENV;
BEGIN {
 open (my $fhSetEnv,'<',substr($0,0,rindex($0,'/')).'/'.SETENV_FILE) || die 'Cant set environment: '.SETENV_FILE.' not found!';
 %SETENV=map { chomp; $_=~m/^\s*(?<KEY>[A-Za-z0-9_-]+)\s*=\s*(?:(?<QUO>['"])(?<VAL>[^\g{QUO}]+?)\g{QUO}|(?<VAL>[^'"[:space:]]+?))\s*$/?($+{'KEY'},$+{'VAL'}):('NOTHING','NOWHERE') } grep { $_ !~ m/^\s*(?:#.*)?$/ } <$fhSetEnv>;
 push @INC,split(/\;/,$SETENV{'PERL_LIBS'}) if $SETENV{'PERL_LIBS'};
 close($fhSetEnv);
}

use Monitoring::Zabipi qw(zbx zbx_last_err zbx_api_url);
no warnings;

my $firstarg=shift;
my $apiPars={'wildcards'=>'true'};
if ($firstarg eq '-x') {
 $apiPars->{'debug'}=1;
 $apiPars->{'pretty'}=1;
} else {
 unshift @ARGV,$firstarg;
}

die 'You must specify ZBX_HOST or ZBX_URL in your config '.SETENV_FILE 
 unless my $zbxConnectTo=$SETENV{'ZBX_HOST'} || $SETENV{'ZBX_URL'};
die 'Cant initialize API, check connecton parameters (ZBX_HOST or ZBX_URL in your config '.SETENV_FILE
 unless Monitoring::Zabipi->new($zbxConnectTo, $apiPars);
zbx('auth',@SETENV{'ZBX_LOGIN','ZBX_PASS'}) || 
 die 'I cant authorize you on ',$zbxConnectTo,". Check your credentials and run this script with the first key '-x' to know why this happens exactly\n";

# Your code goes here ->
my %Hosts=map {$_->{'hosts'}[0]{'host'}=>1} @{zbx('queue.get')};

do {
 print STDERR 'No problem hosts found un queue',"\n";
 exit 0
} unless %Hosts;

%Hosts=map { $_->{'host'}=>$_->{'interfaces'}[0]{'ip'} } grep {$_}
 ( map { zbx('host.get',{'search'=>{'host'=>$_},  'filter'=>{'status'=>0,'maintenance_status'=>0},               'output'=>['host'],'selectInterfaces'=>['ip']})->[0] } keys %Hosts ),
 (    @{ zbx('host.get',{'search'=>{'error'=>'*'},'filter'=>{'status'=>0,'maintenance_status'=>0,'available'=>2},'output'=>['host'],'selectInterfaces'=>['ip']})      }             );

print join("\n",(map { $_.','.$Hosts{$_} } sort keys %Hosts),'');

END {
 zbx('logout') if zbx_api_url;
}
