#!/usr/bin/perl

package StateNotes;

use strict;
use warnings;

use Text::ASCIITable;
use Carp qw( croak carp );

sub get {
    my ( $statewise, $hide, $show, $rows_to_print ) = @_;
    my $table = Text::ASCIITable->new( { drawRowLine => 1 } );
    $table->setCols( qw( State Notes ) );
    $table->setColWidth( 'Notes', 74 );

    my $rows_in_table = 0;
    foreach my $i ( 0 ... scalar @$statewise - 1 ) {
        # $rows_printed is incremented at the end of this foreach
        # loop.
        if ( $rows_to_print ) {
            last if $rows_in_table == $rows_to_print;
        }

        my $state = $statewise->[$i]{state};

        # If user has asked to show specific states then forget about
        # hide option.
        if ( scalar keys %$show ) {
            next
                unless exists $show->{lc $state}
                or ( length $state > 16
                     and exists $show->{lc $statewise->[$i]{statecode}});
        } else {
            next
                if exists $hide->{lc $state}
                # User sees the statecode if length $state > 16 so we
                # also match against that.
                or ( length $state > 16
                     and exists $hide->{lc $statewise->[$i]{statecode}});
        }

        $state = $statewise->[$i]{statecode}
            if length $state > 16;

        unless ( length($statewise->[$i]{statenotes}) == 0 ) {
            $table->addRow(
                $state,
                $statewise->[$i]{statenotes},
            ) ;
            $rows_in_table++;
        }
    }
    return ( $table, $rows_in_table );
}

1;
