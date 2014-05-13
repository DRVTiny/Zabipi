#!/usr/bin/perl -CS
use utf8;
my $group=shift;
BEGIN {
 unshift(@INC,'/home/drvtiny/Apps/Perl5/libs');
}
use Monitoring::Zabipi qw(zbx);

Monitoring::Zabipi->new('zabbix.example.com');

zbx('auth','Admin','ExamplePass');

my $grpid=zbx('usergroup.get',{search=>{name=>$group},output=>['usrgrpid']})->[0]{'usrgrpid'};
print $grpid."\n";
my $uattrs=['alias','name','surname','userid'];
foreach my $user ( @{ zbx('user.get',{usrgrpids=>$grpid,output=>$uattrs}) } ) {
 $$_=$user->{$_} foreach @{$uattrs};
 foreach my $sendto ( map { $_->{'sendto'} } @{ zbx('usermedia.get',{userids=>$userid,output=>['sendto']}) } ) { 
  print join(' ',($alias,$name,$surname,$sendto))."\n";
 }
}
