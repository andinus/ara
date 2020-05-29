#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';

use DateTime qw( );
use Path::Tiny;
use File::Fetch;
use JSON::MaybeXS qw( decode_json );
use Text::Table::Tiny qw( generate_table );

use OpenBSD::Unveil;

# Unveil @INC.
foreach my $path (@INC) {
    unveil( $path, 'rx' ) or
        die "Unable to unveil: $!";
}

# %unveil contains list of paths to unveil with their permissions.
my %unveil = (
    "/" => "rx", # Unveil "/", remove this later after profiling with
                 # ktrace.
    "/home" => "", # Veil "/home", we don't want to read it.
    "/tmp" => "rwc",
    "/dev/null" => "rw",
    );

# Unveil each path from %unveil.
keys %unveil;
while( my( $path, $permission ) = each %unveil ) {
    unveil( $path, $permission ) or
        die "Unable to unveil: $!";
}

# Fetch latest data from api.
my $url = 'https://api.covid19india.org/data.json';
my $ff = File::Fetch->new(uri => $url);

# Save the api response under /tmp.
my $file = $ff->fetch( to => '/tmp' ) or
    die $ff->error;

# Slurp api response to $file_data.
my $file_data = path($file)->slurp;

# Block further unveil calls.
unveil() or
    die "Unable to lock unveil: $!";

# Decode $file_data to $json_data.
my $json_data = decode_json($file_data);

# Get statewise information.
my @statewise = ${$json_data}{'statewise'};

# Map month number to Months.
my @months = qw( lol Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );

my $rows = [
    ['State', 'Confirmed', 'Active', 'Recovered', 'Deaths', 'Last Updated'],
    ];

my $today = DateTime->now( time_zone => 'Asia/Kolkata' );

# Add first 37 entries to $rows.
foreach my $i (0...37) {
    my $update_info;
    my $lastupdatedtime = $statewise[0][$i]{'lastupdatedtime'};
    my $last_update_dmy = substr( $lastupdatedtime, 0, 10 );

    # Add $update_info.
    if ( $last_update_dmy eq $today->dmy('/') ) {
        $update_info = "Today";
    } elsif ( $last_update_dmy eq
              $today->clone->subtract( days => 1 )->dmy('/') ) {
        $update_info = "Yesterday";
    } elsif ( $last_update_dmy eq
              $today->clone->add( days => 1 )->dmy('/') ) {
        $update_info = "Tomorrow"; # Hopefully we don't see this.
    } else {
        $update_info =
            $months[substr( $lastupdatedtime, 3, 2 )] .
            " " .
            substr( $lastupdatedtime, 0, 2 );
    }

    my $state = $statewise[0][$i]{'state'};
    $state = "India" if
        $state eq "Total";

    $state = $statewise[0][$i]{'statecode'} if
        length($state) > 16;

    push @$rows, [
        $state,
        "$statewise[0][$i]{'confirmed'} (+$statewise[0][$i]{'deltaconfirmed'})" ,
        $statewise[0][$i]{'active'},
        "$statewise[0][$i]{'recovered'} (+$statewise[0][$i]{'deltadeaths'})",
        "$statewise[0][$i]{'deaths'} (+$statewise[0][$i]{'deltarecovered'})",
        $update_info,
        ];
}

# Generate table.
say generate_table(rows => $rows, header_row => 1);
