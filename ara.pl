#!/usr/bin/perl

use strict;
use warnings;
use feature 'say';

use YAML qw( Bless Dump );
use Path::Tiny;
use File::Fetch;
use Data::Dumper;
use JSON::MaybeXS;

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

# Print total.
my $total = $json_data->{'statewise'}[0];

Bless($total)->keys( ['confirmed', 'recovered', 'active', 'deaths'] );
print Dump $total;
