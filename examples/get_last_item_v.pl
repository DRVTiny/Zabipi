#!/usr/bin/perl
BEGIN {
 unshift(@INC,'/home/drvtiny/Apps/Perl5/libs');
}
use Monitoring::Zabipi qw(zbx);

Monitoring::Zabipi->new('zabbix.example.com',{'debug'=>'true'});
zbx('auth','Admin','ExamplePass');
my $iv=zbx('item.get',{
 'host'=>'GUF2-AD01',
 'output'=>'extend',
 'monitored'=>'true'
                      });

foreach my $item (@$iv) {
 print <<EOITEM;
===========================
Name: $item->{name}
Last value: $item->{lastvalue}
Last clock: $item->{lastclock}
===========================

EOITEM
}
                      