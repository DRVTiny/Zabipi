#!/usr/bin/perl
#
# Output SQL dump (series of UPDATEs) to fix templated items which has 
# positional macroses in its names (i.e. $1, $2...)
# Reason:
# According to Zabbix 6.0 upgrade notes 
#   https://www.zabbix.com/documentation/6.0/en/manual/installation/upgrade_notes_600#positional_macros_no_longer_supported 
# - positional macroses are no longer considered to be deprecated, since 6.0 its not supported anymore
#

use 5.16.1;
use lib 'lib';
use Monitoring::Zabipi;
use Monitoring::Zabipi::Common qw[doItemNameExpansion];
use Monitoring::Zabipi::SetEnv qw[zbx_setenv];

my $zenv = zbx_setenv;
#die Dumper $zenv;
Monitoring::Zabipi->new($zenv->{'ZBX_URL'}, {wildcards  => 1});
zbx('auth', @{$zenv}{qw[ZBX_LOGIN ZBX_PASS]}) ;

my $cmnItemGetPars = {
    templated 	=>  1,
    search	=> {'name' => '*$*'},
    output 	=> ['name', 'key_', 'itemid'],
};

doItemNameExpansion(
    my $items = [ 
        map @{zbx($_ . '.get' => $cmnItemGetPars)}, qw[item itemprototype]
    ]
);

say join("\n" => 
        map 
            sprintf(q<UPDATE items SET name='%s' WHERE itemid=%d;>, $_->{'name_expanded'} =~ s%'%''%gr, $_->{'itemid'}),
            @{$items}
);
