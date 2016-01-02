#!/usr/bin/perl -CS
use utf8;
my $ip=shift;
BEGIN {
 unshift(@INC,'/home/drvtiny/Apps/Perl5/libs');
}
use Monitoring::Zabipi qw(zbx);

Monitoring::Zabipi->new('zabbix.example.com');

zbx('auth','Admin','ExamplePass');

my $interfaceId=zbx('hostinterface.get',{search=>{ip=>$ip},output=>['interfaceid']})->[0]{interfaceid};

print join("\n",
 map { $_->{'host'} } @{ zbx('host.get',{'interfaceids'=>$interfaceId, output=>['host']}) } 
           ),"\n";
