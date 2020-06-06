#!/usr/bin/perl

use strict;
use warnings;

use Path::Tiny;
use Time::Moment;
use Text::ASCIITable;
use Getopt::Long qw( GetOptions );
use JSON::MaybeXS qw( decode_json );

use OpenBSD::Unveil;

# Unveil @INC.
foreach my $path (@INC) {
    unveil( $path, 'rx' ) or
        die "Unable to unveil: $!";
}

my ( $use_local_file, $get_latest, $state_notes, $rows_to_print );

GetOptions(
    "local" => \$use_local_file,
    "latest" => \$get_latest,
    "notes" => \$state_notes,
    "rows=i" => \$rows_to_print,
    "help" => sub { HelpMessage() },
    ) or
    die "Error in command line arguments";

sub HelpMessage {
    print "Options:
    --local  Use local data
    --latest Fetch latest data
    --notes  Print State Notes
    --rows=i Number of rows to print (i is Integer)
    --help   Print this help message
";
    exit;
}

die "Can't use --local and --latest together\n" if
    ( $use_local_file and $get_latest );

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
    $file_mtime = Time::Moment->from_epoch( $file_stat->[9] );
} else {
    warn "File '$file' doesn't exist\nFetching latest...\n" if
        $use_local_file;
}

# Fetch latest data only if the local data is older than 8 minutes or
# if the file doesn't exist.
if ( ( not -e $file ) or
     ( $file_mtime <
       Time::Moment->now_utc->minus_minutes(8) ) or
     $get_latest ) {
    require File::Fetch;

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


my ( $covid_19_data, $notes_table, @months, $today );

if ( $state_notes ) {
    $notes_table = Text::ASCIITable->new( { drawRowLine => 1 } );
    $notes_table->setCols( qw( State Notes ) );
    $notes_table->setColWidth( 'Notes', 74 );
} else {
    # Map month number to Months.
    @months = qw( lol Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec );

    $covid_19_data = Text::ASCIITable->new();
    $covid_19_data->setCols( 'State',
                             'Confirmed',
                             'Active',
                             'Recovered',
                             'Deaths',
                             'Last Updated',
        );

    $covid_19_data->alignCol( { 'Confirmed' => 'left',
                                    'Recovered' => 'left',
                                    'Deaths' => 'left',
                              } );
    $today = Time::Moment
        ->now_utc
        ->plus_hours(5)
        ->plus_minutes(30); # Current time in 'Asia/Kolkata' TimeZone.
}

# Print all the rows if $rows_to_print evaluates to False or is
# greater than the size of @$statewise or if user wants $state_notes.
$rows_to_print = scalar @$statewise if
    ( ( not $rows_to_print ) or
      ( $rows_to_print > scalar @$statewise ) or
      $state_notes );

foreach my $i ( 0 ... $rows_to_print - 1  ) {
    my $state = $statewise->[$i]{state};
    $state = "India" if
        $state eq "Total";

    $state = $statewise->[$i]{statecode} if
        length($state) > 16;

    if ( $state_notes ) {
        $notes_table->addRow(
            $state,
            $statewise->[$i]{statenotes},
            ) unless
            length($statewise->[$i]{statenotes}) == 0;
    } else {
        my $update_info;
        my $lastupdatedtime = $statewise->[$i]{lastupdatedtime};
        my $last_update_dmy = substr( $lastupdatedtime, 0, 10 );

        # Add $update_info.
        if ( $last_update_dmy eq $today->strftime( "%d/%m/%Y" ) ) {
            $update_info = "Today";
        } elsif ( $last_update_dmy eq
                  $today->minus_days(1)->strftime( "%d/%m/%Y" ) ) {
            $update_info = "Yesterday";
        } elsif ( $last_update_dmy eq
                  $today->plus_days(1)->strftime( "%d/%m/%Y" ) ) {
            $update_info = "Tomorrow"; # Hopefully we don't see this.
        } else {
            $update_info =
                $months[substr( $lastupdatedtime, 3, 2 )] .
                " " .
                substr( $lastupdatedtime, 0, 2 );
        }

        my $confirmed = "$statewise->[$i]{confirmed}";
        my $recovered = "$statewise->[$i]{recovered}";
        my $deaths = "$statewise->[$i]{deaths}";

        # Add delta only if it was updated Today.
        if ( $update_info eq "Today" ) {
            $confirmed .= " (+$statewise->[$i]{deltaconfirmed})";
            $recovered .= " (+$statewise->[$i]{deltarecovered})";
            $deaths .= " (+$statewise->[$i]{deltadeaths})";
        }

        $covid_19_data->addRow(
            $state,
            $confirmed,
            $statewise->[$i]{active},
            $recovered,
            $deaths,
            $update_info,
            );
    }
}

# Generate tables.
if ( $state_notes ) {
    print $notes_table;
} else {
    print $covid_19_data;
}
