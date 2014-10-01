#!/usr/bin/perl -CDA
use strict;
use utf8;
use constant {
     SETENV_FILE=>'setenv.conf',
     TIMEZONE=>'MSK',
};
my %SETENV;

BEGIN {
 open (FH,'<',substr($0,0,rindex($0,'/')).'/'.SETENV_FILE) || die 'Cant set environment: '.SETENV_FILE.' not found!';
 %SETENV=map { chomp; $_=~m/^\s*(?<KEY>[A-Za-z0-9_-]+)\s*=\s*(?:(?<QUO>['"])(?<VAL>[^\g{QUO}]+?)\g{QUO}|(?<VAL>[^'"[:space:]]+?))\s*$/?($+{'KEY'},$+{'VAL'}):('NOTHING','NOWHERE') } grep { $_ !~ m/^\s*(?:#.*)?$/ } <FH>;
 push @INC,split(/\;/,$SETENV{'PERL_LIBS'}) if $SETENV{'PERL_LIBS'};
 close(FH);
}

use Monitoring::Zabipi qw(zbx);
no warnings;

my %FE;
@FE{'login','server','pass'}=@SETENV{'ZBX_LOGIN','ZBX_HOST','ZBX_PASS'};

my $dbg={};
my $firstarg=shift;
if ($firstarg eq '-x') {
 $dbg={'debug'=>1};
} else {
 unshift @ARGV,$firstarg;
}

Monitoring::Zabipi->new($FE{'server'},$dbg);
zbx('auth',$FE{'login'},$FE{'pass'}) || die 'I cant authorize you on '.$FE{'server'}."\!\n";

my %Hosts=map {$_->{'hosts'}[0]{'host'}=>1} @{zbx('queue.get')};
%Hosts=map { $_->{'host'}=>$_->{'interfaces'}[0]{'ip'} } grep {$_}
 ( map { zbx('host.get',{'search'=>{'host'=>$_},  'filter'=>{'status'=>0,'maintenance_status'=>0},               'output'=>['host'],'selectInterfaces'=>['ip']})->[0] } keys %Hosts ),
 (    @{ zbx('host.get',{'search'=>{'error'=>'*'},'filter'=>{'status'=>0,'maintenance_status'=>0,'available'=>2},'output'=>['host'],'selectInterfaces'=>['ip']})      }             );
 
print join("\n",(map { $_.','.$Hosts{$_} } sort keys %Hosts),'');

END {
 zbx('logout');
}
