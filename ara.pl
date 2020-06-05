#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';

use DateTime qw( );
use Path::Tiny;
use File::Fetch;
use JSON::MaybeXS qw( decode_json );
use Text::Table::Tiny qw( generate_table );
use Text::ASCIITable;

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

my $file = '/tmp/data.json';
my $file_mtime;

# If $file exists then get mtime.
if ( -e $file ) {
    my $file_stat = path($file)->stat;
    $file_mtime = DateTime->from_epoch(
        epoch => $file_stat->[9],
        time_zone => 'Asia/Kolkata',
        );
}

# Fetch latest data only if the local data is older than 8 minutes or
# if the file doesn't exist.
if ( ( not -e $file ) or
     ( $file_mtime <
       DateTime->now( time_zone => 'Asia/Kolkata' )->subtract( minutes => 8 ) ) ) {
    # Fetch latest data from api.
    my $url = 'https://api.covid19india.org/data.json';
    my $ff = File::Fetch->new(uri => $url);

    # Save the api response under /tmp.
    $file = $ff->fetch( to => '/tmp' ) or
        die $ff->error;
}

# Slurp api response to $file_data.
my $file_data = path($file)->slurp;

# Block further unveil calls.
unveil() or
    die "Unable to lock unveil: $!";

# Decode $file_data to $json_data.
my $json_data = decode_json($file_data);

# Get statewise information.
my $statewise = $json_data->{statewise};

# Map month number to Months.
my @months = qw( lol Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );

my $covid_19_data = [
    ['State', 'Confirmed', 'Active', 'Recovered', 'Deaths', 'Last Updated'],
    ];

my $state_notes = Text::ASCIITable->new( { drawRowLine => 1 } );
$state_notes->setCols( 'State', 'Notes' );
$state_notes->setColWidth( 'Notes', 84 );

my $today = DateTime->now( time_zone => 'Asia/Kolkata' );

# Add first 37 entries to $rows.
foreach my $i (0...37) {
    my $update_info;
    my $lastupdatedtime = $statewise->[$i]{'lastupdatedtime'};
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

    my $state = $statewise->[$i]{'state'};
    $state = "India" if
        $state eq "Total";

    $state = $statewise->[$i]{'statecode'} if
        length($state) > 16;

    my $confirmed = "$statewise->[$i]{confirmed}";
    my $recovered = "$statewise->[$i]{recovered}";
    my $deaths = "$statewise->[$i]{deaths}";

    # Add delta only if it was updated Today.
    if ( $update_info eq "Today" ) {
        $confirmed .= " (+$statewise->[$i]{deltaconfirmed})";
        $recovered .= " (+$statewise->[$i]{deltarecovered})";
        $deaths .= " (+$statewise->[$i]{deltadeaths})";
    }

    push @$covid_19_data, [
        $state,
        $confirmed,
        $statewise->[$i]{'active'},
        $recovered,
        $deaths,
        $update_info,
        ];

    $state_notes->addRow(
        $state,
        $statewise->[$i]{statenotes},
        ) unless
        length($statewise->[$i]{statenotes}) eq 0;
}

# Generate tables.
say generate_table(rows => $covid_19_data, header_row => 1);
print $state_notes;
