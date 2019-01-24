#!/usr/bin/env perl
# vim: sw=4 ts=4 et

# please do following before executing this script:
#
# $ sudo apt-get update
# $ sudo apt-get -y install libmodule-path-perl libperl-prereqscanner-perl apt-file

use strict;
use warnings;

use Carp;
use File::Next;
use File::Spec::Functions qw( :ALL );
use File::Temp;

use Module::Path 'module_path';
use Perl::PrereqScanner;

my $scanner = Perl::PrereqScanner->new;

my $root = @ARGV ? $ARGV[0] : '.';

sub get_missing_modules {
    my %local_modules;
    my $iter = File::Next::files(
        {
            # file_filter    => sub { /\.(pl|pm|t)$/ || !/\./ },
            file_filter    => sub {/\.(pl|pm|t)$/},
            descend_filter => sub { $_ ne "CVS" && $_ ne ".svn" },
        },
        $root
    );

    my %deps;
    while ( defined( my $file = $iter->() ) ) {
        if ( $file =~ /\.pm$/ ) {
            my $path = abs2rel( $file, $root );
            $path =~ s/\.pm$//;
            my @dirs = splitdir($path);
            for my $i ( 0 .. $#dirs ) {
                $local_modules{ join '::', @dirs[ $#dirs - $i .. $#dirs ] }
                    = $file;
            }
        }
        eval {
            my %required_modules = map { $_ => 1 }
                grep { defined $_ && $_ ne 'perl' }
                $scanner->scan_file($file)->required_modules();

            %deps = ( %deps, %required_modules );
        };
        if ($@) {
            warn $@;
        }
    }

    my @modules = sort { $a cmp $b }
        grep { !defined module_path($_) }
        grep { !exists $local_modules{$_} }
        keys %deps;

    return @modules;
}

sub file_name {
    my ($module) = @_;
    $module =~ s(::)(/)g;
    return "$module.pm";
}

sub apt_name {
    my ($perl_module) = @_;

    my $apt = lc $perl_module;
    $apt =~ s(::)(-)g;
    return "lib${apt}-perl";
}

my %modules = map { $_ => { file => file_name($_), apt => apt_name($_) } }
    get_missing_modules();

if ( !%modules ) {
    exit 0;
}

my %apt;

# using apt-cache
my $re = join '|', map {"^$_->{apt}\$"} values %modules;
my $cmd = "apt-cache search '$re'";
for my $line (qx($cmd)) {
    chomp $line;
    if ( $line =~ /^(lib\S+-perl) - / ) {
        $apt{$1} = 1;

        while ( my ( $k, $v ) = each %modules ) {
            if ( $line =~ /^$v->{apt}/ ) {
                delete $modules{$k};
            }
        }
    }
}

# using apt-file
my $tmp = File::Temp->new();
$tmp->autoflush();
print $tmp map {"$_->{file}\n"} values %modules;

$cmd = 'apt-file -f search ' . $tmp->filename;
for my $line (qx($cmd)) {
    chomp $line;
    if ( $line =~ /^(lib\S+-perl|perl-\S+): / ) {
        $apt{$1} = 1;

        while ( my ( $k, $v ) = each %modules ) {
            ## NB: dangerous, can match multiple packages
            if ( $line =~ /$v->{file}$/ ) {
                delete $modules{$k};
            }
        }
    }
}

my @apt = sort { $a cmp $b } keys %apt;

print "# aptitude\n";
print 'sudo apt-get -y install ', join( ' ', @apt ), qq(\n);
print qq(\n);

print "# cpan\n";
print 'yes | cpan -i ', join( ' ', sort { $a cmp $b } keys %modules ), qq(\n);