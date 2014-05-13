#!/usr/bin/perl -CS
use utf8;
BEGIN {
 unshift(@INC,'/home/drvtiny/Apps/Perl5/libs');
}
use Monitoring::Zabipi qw(zbx);

Monitoring::Zabipi->new('zabbix.example.com');

zbx('auth','Admin','ExamplePass');

my %seen;
foreach my $hostid ( grep { ! $seen{$_}++ } map { $_->{'hostid'} } 
@{
  zbx(
  'item.get',
   {
    'search'=>{ 'key_'=>'quality.param' },
    'output'=>['hostid'],
    'monitored'=>'true',
   }
     )
 }                 )
{
 
 print <<EOPRINT;
=== HOST: $hostid ===
KEY;NAME;VALUE
EOPRINT
 foreach my $item ( @{
                      zbx('item.get',{ 'search'=>{ 'key_'=>'quality.param' },'hostids'=>$hostid,'output'=>['key_','name','lastvalue','lastclock'] }) 
                      } )
 {
  print $item->{'key_'}.';"'.$item->{'name'}.'";'.$item->{'lastvalue'}.';'.scalar(localtime($item->{'lastclock'}))."\n";
 } 
}
        
exit(0);

zbx('item.get',
{ 
 'hostids'=>[ map { $_->{'hostid'} } @{ zbx('host.get', { 'output'=>'shorten', 'itemids'=>[ map { $_->{'itemid'} } @{ zbx('item.get',
  {
   'search'=>{ 'key_'=>'quality.param' },
   'output'=>'refer',
   'monitored'=>'true',
  }              ) } ] 
                }
                  ) }
             ],
  'output'=>'extend',
  'monitored'=>'true',
}
);
                      