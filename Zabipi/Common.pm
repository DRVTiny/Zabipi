package Monitoring::Zabipi::Common;
use 5.16.1;
use Exporter qw(import);
use JSON::XS;

our @EXPORT_OK = qw(fillHashInd to_json_str doItemNameExpansion);

sub fillHashInd {
    my ( $d, @i ) = @_;
    if ( @i == 1 ) {
        return \$d->{ $i[0] };
    }
    else {
        my $e = shift @i;
        fillHashInd( $d->{$e} = $d->{$e} || {}, @i );
    }
}

sub to_json_str {
    my ( $cfg, $plStruct ) = @_;
    return 0 unless defined $plStruct and ref($plStruct) =~ m/^(?:ARRAY|HASH)?$/;
    if ( ref $plStruct ) {
        return $cfg->{'flPrettyJSON'} ? JSON::XS->new->utf8->pretty(1)->encode($plStruct) : encode_json($plStruct);
    }
    else {
        return $cfg->{'flPrettyJSON'} ? JSON::XS->new->utf8->pretty(1)->encode( decode_json($plStruct) ) : $plStruct;
    }
}

sub doItemNameExpansion {
    my ( $items, @unsetKeys ) = @_;

    for my $item ( @{$items} ) {
        my ( $itemName, $itemKeyArgs ) = @{$item}{qw[name key_]};
        my %posMacroUsedInName = map { $_ => 1 } ( $itemName =~ m/\$([1-9])/g );
        unless ( %posMacroUsedInName ) {
            $item->{'name_expanded'} = $itemName;
            next
        }
        
        
        # item_key[item_args] => item_args
        s%[^\[]+\[\s*%%, s%\]\s*$%% for $itemKeyArgs;

        my @posKeyArgs = map s%^(?<QUO>["'])(?<KEY>.+?)\g{QUO}$%$+{KEY}%r,
                            $itemKeyArgs =~ m{
                                (?:^|,)\s*
                                (
                                    (?<Q>["'`])((?:(?!\k<Q>|\\).|\\.)*)\k<Q>|
                                    [^,]*
                                )
                                \s*(?=(?:,|$))
                            }gx;
                            
        $itemName =~ s{
                  \$$_
                }{
                  $posKeyArgs[$_-1]
                }gex for keys %posMacroUsedInName;
        
        $item->{'name_expanded'} = $itemName;
        delete @{$item}{@unsetKeys} if @unsetKeys;
    }
    return 1
}

1;
