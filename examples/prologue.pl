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

use POSIX qw(strftime);
use Date::Parse qw(str2time);
use Monitoring::Zabipi qw(zbx zbx_last_err);
no warnings;
use Data::Dumper;

my %FE;
@FE{('login','server','pass')}=@SETENV{('ZBX_LOGIN','ZBX_HOST','ZBX_PASS')};

my $firstarg=shift;
my $apiPars={'wildcards'=>'true'};
if ($firstarg eq '-x') {
 $apiPars->{'debug'}=1;
} else {
 unshift @ARGV,$firstarg;
}

Monitoring::Zabipi->new($FE{'server'},$apiPars);
zbx('auth',$FE{'login'},$FE{'pass'}) || die 'Oh, shit, i cant authorize you on '.$FE{'server'}."\!\n";

# Your code goes here ->

END {
 zbx('logout');
}
