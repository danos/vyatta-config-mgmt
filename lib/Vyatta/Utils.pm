package Vyatta::Utils;
use strict;

require Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw(parse_version_string);

sub parse_version_string {
    my $string = shift;
    my @words = split(' ', $string);
    my @version = ();

    while (my $word = pop(@words)) {
	last if @version = ( $word =~ /^(\d+\.)(\d+\.)?(.*|\d+)$/ );
    }

    # e.g. ( "1.", undefined, "2" )
    @version = grep defined, @version;

    return join('', @version);
}

1;
