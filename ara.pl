#!/usr/bin/perl

use strict;
use warnings;

use Path::Tiny;
use Time::Moment;
use Text::ASCIITable;
use Getopt::Long qw( GetOptions );
use JSON::MaybeXS qw( decode_json );
use Term::ANSIColor qw( :pushpop );

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
     $no_total, @to_hide, %hide, @to_show, %show );

GetOptions(
    "local" => \$use_local_file,
    "latest" => \$get_latest,
    "notes" => \$state_notes,
    "rows=i" => \$rows_to_print,
    "nodelta" => \$no_delta,
    "nototal" => \$no_total,
    "hide=s{1,}" => \@to_hide, # Getopt::Long docs say that this is an
                               # experimental feature with a warning.
    "show=s{1,}" => \@to_show,
    "help", "h" => sub { HelpMessage() },
) or die "Error in command line arguments";

if ( $use_local_file
         and $get_latest ) {
    warn LOCALCOLOR YELLOW "Cannot use --local & --latest together
Overriding --latest option";
    undef $get_latest;
}

# To not break --nototal we add "India" to @to_hide.
push @to_hide, "india"
    if $no_total;

# Creating %hide and undefining all %hash{@to_hide}, after this we
# check if %hash{@to_hide} exists with exists keyword. Read this as
# "undef these keys from the hash". https://perldoc.pl/perldata#Slices
undef @hide{ @to_hide }
    if scalar @to_hide; # Array can't be empty, will fail.
                        # Alternatively can do @hide{ @to_hide } = ()
                        # which will work even if @to_hide is empty.

undef @show{ @to_show }
    if scalar @to_show;

# Alias updated to last updated. This will allow user to just enter
# updated in hide option.
undef $hide{'last updated'}
    if exists $hide{updated};

# Warn when user tries to hide these columns.
warn LOCALCOLOR YELLOW "Cannot hide state column" if exists $hide{state};
warn LOCALCOLOR YELLOW "Cannot hide notes column"
    if exists $hide{notes} and $state_notes;

sub HelpMessage {
    print LOCALCOLOR GREEN "Options:
    --local   Use local data
    --latest  Fetch latest data
    --notes   Print State Notes
    --rows=i  Number of rows to print (i is Integer)
    --nodelta Don't print changes in values
    --nototal Don't print 'Total' row
    --hide    Hide states, columns from table (space seperated)
    --show    Show only these states (space seperated)";
    print LOCALCOLOR CYAN "
    --help    Print this help message
";
    exit;
}

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

# Unveil each path from %unveil. We use sort because otherwise keys is
# random order everytime.
foreach my $path ( sort keys %unveil ) {
    unveil( $path, $unveil{$path} )
        or die "Unable to unveil: $!";
}

my $file = "$cache_dir/ara.json";
my $file_mtime;

# If $file exists then get mtime.
if ( -e $file ) {
    my $file_stat = path($file)->stat;
    $file_mtime = Time::Moment->from_epoch( $file_stat->mtime );
} else {
    if ( $use_local_file ) {
        warn LOCALCOLOR YELLOW "File '$file' doesn't exist
Fetching latest...";
        undef $use_local_file;
    }
}

# Fetch latest data only if the local data is older than 8 minutes or
# if the file doesn't exist.
if ( not $use_local_file
         and ( not -e $file
               or $file_mtime < Time::Moment->now_utc->minus_minutes(8)
               or $get_latest ) ) {
    require HTTP::Simple;

    # Ignore a warning, next line would've printed a warning.
    no warnings 'once';
    $HTTP::Simple::UA->verify_SSL(1);

    # Fetch latest data from api.
    my $url = 'https://api.covid19india.org/data.json';

    my $response = HTTP::Simple::getstore($url, $file);

    die "Failed to fetch latest data...
Reason: $response->{reason}\n
Content: $response->{content}
Status: $response->{status}\n"
        unless HTTP::Simple::is_success($response);
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

    my @columns;
    push @columns, 'State'; # User cannot hide state column.
    push @columns, 'Confirmed' unless exists $hide{confirmed};
    push @columns, 'Active' unless exists $hide{active};
    push @columns, 'Recovered' unless exists $hide{recovered};
    push @columns, 'Deaths' unless exists $hide{deaths};
    push @columns, 'Last Updated' unless exists $hide{'last updated'};

    $covid_19_data = Text::ASCIITable->new( { allowANSI => 1 } );
    $covid_19_data->setCols( @columns );

    my %alignment;
    $alignment{Confirmed} = "left" unless exists $hide{confirmed};
    $alignment{Recovered} = "left" unless exists $hide{recovered};
    $alignment{Deaths} = "left" unless exists $hide{deaths};

    $covid_19_data->alignCol( \%alignment );

    $today = Time::Moment
        ->now_utc
        ->plus_hours(5)
        ->plus_minutes(30); # Current time in 'Asia/Kolkata' TimeZone.
}

my $rows_printed = 0;
foreach my $i ( 0 ... scalar @$statewise - 1 ) {
    # $rows_printed is incremented at the end of this foreach loop.
    if ( $rows_to_print ) {
        last if $rows_printed == $rows_to_print;
    }

    my $state = $statewise->[$i]{state};

    $state = "India"
        if $state eq "Total";

    $state = "Unassigned"
        if $state eq "State Unassigned";

    # If user has asked to show specific states then forget about hide
    # option.
    if ( scalar @to_show ) {
        next
            unless exists $show{lc $state}
            or ( length $state > 16
                 and exists $show{lc $statewise->[$i]{statecode}})
    } else {
        next
            if exists $hide{lc $state}
            # User sees the statecode if length $state > 16 so we also
            # match against that.
            or ( length $state > 16
                 and exists $hide{lc $statewise->[$i]{statecode}});
    }

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
                $confirmed .= LOCALCOLOR BLACK ON_MAGENTA
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
                $recovered .= LOCALCOLOR BLACK ON_GREEN
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
                $state = LOCALCOLOR BLACK ON_RED $state;
                $deaths .= LOCALCOLOR BLACK ON_RED
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

        my @row;
        push @row, $state;
        push @row, $confirmed unless exists $hide{confirmed};
        push @row, $statewise->[$i]{active} unless exists $hide{active};
        push @row, $recovered unless exists $hide{recovered};
        push @row, $deaths unless exists $hide{deaths};
        push @row, $update_info unless exists $hide{'last updated'};

        $covid_19_data->addRow( @row );
    }
    $rows_printed++;
}

# Generate tables.
if ( $state_notes ) {
    print $notes_table;
} else {
    print $covid_19_data;
}
