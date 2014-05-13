#!/usr/bin/perl -CS
use utf8;
my $host=shift;
BEGIN {
 unshift(@INC,'/home/drvtiny/Apps/Perl5/libs');
}
use Monitoring::Zabipi qw(zbx);

Monitoring::Zabipi->new('zabbix.example.com');

zbx('auth','Admin','ExamplePass');

my %seen;

my $hostIds=[ map { $_->{'hostid'} } @{ zbx('host.get',{search=>{host=>$host},monitored_hosts=>1,output=>['hostid']}) } ];
print join("\n",map { $_->{'ip'} } @{ zbx('hostinterface.get',{hostids=>$hostIds,output=>['ip']}) } )."\n";
