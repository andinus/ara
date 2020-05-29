#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';

use Path::Tiny;
use File::Fetch;
use Data::Dumper;
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

my $rows = [
    ['State', 'Confirmed', 'Active', 'Recovered', 'Deaths', 'Last Updated'],
    ];

# Add first 37 entries to $rows.
foreach my $i (0...37) {
    my $lastupdatedtime = $statewise[0][$i]{'lastupdatedtime'};
    push @$rows, [
        # Limit the length to 18 characters, this will cut long state
        # names.
        substr( $statewise[0][$i]{'state'}, 0, 18 ),

        "$statewise[0][$i]{'confirmed'} (+$statewise[0][$i]{'deltaconfirmed'})" ,
        $statewise[0][$i]{'active'},
        "$statewise[0][$i]{'recovered'} (+$statewise[0][$i]{'deltadeaths'})",
        "$statewise[0][$i]{'deaths'} (+$statewise[0][$i]{'deltarecovered'})",
        substr( $lastupdatedtime, 0, 5 ),
        ];
}

# Generate table.
say generate_table(rows => $rows, header_row => 1);
