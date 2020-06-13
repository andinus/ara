#!/usr/bin/perl

use strict;
use warnings;

use Path::Tiny;
use Time::Moment;
use Text::ASCIITable;
use Getopt::Long qw( GetOptions );
use JSON::MaybeXS qw( decode_json );
use Term::ANSIColor qw( :pushpop ) ;

use constant is_OpenBSD => $^O eq "openbsd";
require OpenBSD::Unveil
    if is_OpenBSD;
sub unveil {
    if (is_OpenBSD) {
        return OpenBSD::Unveil::unveil(@_);
    } else {
        return 1;
    }
}

# Unveil @INC.
foreach my $path (@INC) {
    unveil( $path, 'rx' )
        or die "Unable to unveil: $!";
}

my ( $use_local_file, $get_latest, $state_notes, $rows_to_print, $no_delta,
     $no_total, @to_hide );

GetOptions(
    "local" => \$use_local_file,
    "latest" => \$get_latest,
    "notes" => \$state_notes,
    "rows=i" => \$rows_to_print,
    "nodelta" => \$no_delta,
    "nototal" => \$no_total,
    "hide=s{1,}" => \@to_hide, # Getopt::Long docs say that this is an
                               # experimental feature with a warning.
    "help", "h" => sub { HelpMessage() },
) or die "Error in command line arguments";

# To not break --nototal we add "India" to @to_hide.
push @to_hide, "india"
    if $no_total;

# Creating %hide and undefining all %hash{@to_hide}, after this we
# check if %hash{@to_hide} exists with exists keyword. Read this as
# "undef these keys from the hash". https://perldoc.pl/perldata#Slices
my %hide;
undef @hide{ @to_hide }
    if scalar @to_hide; # Array can't be empty, will fail.
                        # Alternatively can do @hide{ @to_hide } = ()
                        # which will work even if @to_hide is empty.

sub HelpMessage {
    print LOCALCOLOR GREEN "Options:
    --local   Use local data
    --latest  Fetch latest data
    --notes   Print State Notes
    --rows=i  Number of rows to print (i is Integer)
    --nodelta Don't print changes in values
    --nototal Don't print 'Total' row
    --hide    Hide states from table (space seperated values)";
    print LOCALCOLOR CYAN "
    --help    Print this help message
";
    exit;
}

die "Can't use --local and --latest together\n"
    if $use_local_file and $get_latest ;

my $cache_dir = $ENV{XDG_CACHE_HOME} || "$ENV{HOME}/.cache";

# %unveil contains list of paths to unveil with their permissions.
my %unveil = (
    "/usr" => "rx",
    "/var" => "rx",
    "/etc" => "rx",
    "/dev" => "rx",
    # Unveil the whole cache directory because HTTP::Tiny fetches file
    # like ara.jsonXXXXXXXXXX where each 'X' is a random number.
    $cache_dir => "rwc",
);

# Unveil each path from %unveil.
keys %unveil;
# We use sort because otherwise keys is random order everytime.
foreach my $path ( sort keys %unveil ) {
    unveil( $path, $unveil{$path} )
        or die "Unable to unveil: $!";
}

my $file = "$cache_dir/ara.json";
my $file_ctime;

# If $file exists then get ctime.
if ( -e $file ) {
    my $file_stat = path($file)->stat;
    $file_ctime = Time::Moment->from_epoch( $file_stat->ctime );
} else {
    warn "File '$file' doesn't exist\nFetching latest...\n"
        if $use_local_file;
}

# Fetch latest data only if the local data is older than 8 minutes or
# if the file doesn't exist.
if ( not -e $file
         or $file_ctime < Time::Moment->now_utc->minus_minutes(8)
         or $get_latest ) {
    require HTTP::Tiny;

    # Fetch latest data from api.
    my $url = 'https://api.covid19india.org/data.json';

    my $response = HTTP::Tiny
        ->new( verify_SSL => 1 )
        ->mirror($url, $file);

    die "Failed to fetch latest data...
Reason: $response->{reason}\n
Content: $response->{content}
Status: $response->{status}\n"
        unless $response->{success};
}

# Slurp api response to $file_data.
my $file_data = path($file)->slurp;

# Block further unveil calls.
unveil()
    or die "Unable to lock unveil: $!";

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

    $covid_19_data = Text::ASCIITable->new( { allowANSI => 1 } );
    $covid_19_data->setCols(
        'State',
        'Confirmed',
        'Active',
        'Recovered',
        'Deaths',
        'Last Updated',
    );

    $covid_19_data->alignCol( {
        'Confirmed' => 'left',
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
$rows_to_print = scalar @$statewise
    if ( not $rows_to_print
             or $rows_to_print > scalar @$statewise
             or $state_notes );

foreach my $i ( 0 ... $rows_to_print - 1  ) {
    my $state = $statewise->[$i]{state};

    $state = "India"
        if $state eq "Total";

    $state = "Unassigned"
        if $state eq "State Unassigned";

    next
        if exists $hide{lc $state}
        # User sees the statecode if length $state > 16 so we also
        # match against that.
        or ( length $state > 16
             and exists $hide{lc $statewise->[$i]{statecode}});

    $state = $statewise->[$i]{statecode}
        if length $state > 16;

    if ( $state_notes ) {
        $notes_table->addRow(
            $state,
            $statewise->[$i]{statenotes},
        ) unless length($statewise->[$i]{statenotes}) == 0;
    } else {
        my $update_info;
        my $lastupdatedtime = $statewise->[$i]{lastupdatedtime};
        my $last_update_dmy = substr( $lastupdatedtime, 0, 10 );

        # Add $update_info.
        if ( $last_update_dmy
                 eq $today->strftime( "%d/%m/%Y" ) ) {
            $update_info = "Today";
        } elsif ( $last_update_dmy
                      eq $today->minus_days(1)->strftime( "%d/%m/%Y" ) ) {
            $update_info = "Yesterday";
        } elsif ( $last_update_dmy
                      eq $today->plus_days(1)->strftime( "%d/%m/%Y" ) ) {
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
        if ( $update_info eq "Today"
                 and not $no_delta ) {
            my $delta_confirmed = $statewise->[$i]{deltaconfirmed};
            if ( $delta_confirmed > 1000 ) {
                $confirmed .= LOCALCOLOR ON_MAGENTA
                    sprintf " (%+d)", $statewise->[$i]{deltaconfirmed};
            } elsif ( $delta_confirmed > 500  ) {
                $confirmed .= LOCALCOLOR BRIGHT_MAGENTA
                    sprintf " (%+d)", $statewise->[$i]{deltaconfirmed};
            } elsif ( $delta_confirmed > 100 ) {
                $confirmed .= LOCALCOLOR MAGENTA
                    sprintf " (%+d)", $statewise->[$i]{deltaconfirmed};
            } else {
                $confirmed .= sprintf " (%+d)", $statewise->[$i]{deltaconfirmed};
            }

            my $delta_recovered = $statewise->[$i]{deltarecovered};
            if ( $delta_recovered > 1000 ) {
                $recovered .= LOCALCOLOR ON_GREEN
                    sprintf " (%+d)", $statewise->[$i]{deltarecovered};
            } elsif ( $delta_recovered > 500 ) {
                $recovered .= LOCALCOLOR BRIGHT_GREEN
                    sprintf " (%+d)", $statewise->[$i]{deltarecovered};
            } elsif ( $delta_recovered > 100 ) {
                $recovered .= LOCALCOLOR GREEN
                    sprintf " (%+d)", $statewise->[$i]{deltarecovered};
            } else {
                $recovered .= sprintf " (%+d)", $statewise->[$i]{deltarecovered};
            }

            my $delta_deaths = $statewise->[$i]{deltadeaths};
            if ( $delta_deaths > 100 ) {
                $state = LOCALCOLOR ON_RED $state;
                $deaths .= LOCALCOLOR ON_RED
                    sprintf " (%+d)", $statewise->[$i]{deltadeaths};
            } elsif ( $delta_deaths > 50 ) {
                $state = LOCALCOLOR BRIGHT_RED $state;
                $deaths .= LOCALCOLOR BRIGHT_RED
                    sprintf " (%+d)", $statewise->[$i]{deltadeaths};
            } elsif ( $delta_deaths > 25 ) {
                $state = LOCALCOLOR RED $state;
                $deaths .= LOCALCOLOR RED
                    sprintf " (%+d)", $statewise->[$i]{deltadeaths};
            } else {
                $deaths .= sprintf " (%+d)", $statewise->[$i]{deltadeaths};
            }
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
