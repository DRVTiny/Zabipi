use strict;
use warnings;
use Exporter qw(import);
our @EXPORT=qw/zbx_setenv/;
use constant DFLT_SETENV_PATH=>'/etc/zabbix/api/setenv.conf';

sub zbx_setenv {
  my $pthSetEnvFile=shift // DFLT_SETENV_PATH();
  open (my $fhSetEnv,'<',$pthSetEnvFile) or die sprintf('Cant get environment from file %s: %s', $pthSetEnvFile, $!);
  my %zbxEnv=map { chomp; $_=~m/^\s*(?<KEY>[A-Za-z0-9_-]+)\s*=\s*(?:(?<Q>["'])(?<VAL>((?!\g{Q}).)*)\g{Q}|(?<VAL>[^'"[:space:]]+?))\s*$/?($+{'KEY'},$+{'VAL'}):('NOTHING','NOWHERE') } grep { $_ !~ m/^\s*(?:#.*)?$/ } <$fhSetEnv>;
  if (${^GLOBAL_PHASE} eq 'START' and exists $zbxEnv{'PERL_LIBS'} and $zbxEnv{'PERL_LIBS'}) {
    my %INCIndex=do { my $c=0; map {$_=>$c++} split(/\;/ => $zbxEnv{'PERL_LIBS'}), @INC };
    @INC=sort {$INCIndex{$a} <=> $INCIndex{$b}} keys %INCIndex;
  }
  return \%zbxEnv
}

1;
