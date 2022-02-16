#!/usr/bin/env perl
# vim: sw=4 ts=4 et

# please do following before executing this script:
#
# Debian/Ubuntu Linux:
#
# $ sudo apt-get update
# $ sudo apt-get -y install libmodule-path-perl libperl-prereqscanner-perl apt-file
#
# OSX:
#
# $ sudo port selfupdate
# $ sudo port upgrade outdated
# $ sudo port -N install p5-module-path p5-perl-prereqscanner p5-ipc-system-simple p5-libwww-perl

use strict;
use warnings;
use autodie ':all';

use Carp;
use English '-no_match_vars';
use Fcntl ':flock';
use File::Find;
use File::Spec::Functions ':ALL';
use File::Temp;
use Getopt::Long;
use IO::Zlib;
use LWP::Simple;
use Pod::Usage;

use Data::Dump;

use Module::Path 'module_path';
use Perl::PrereqScanner;

my $packages = '02packages.details.txt.gz';
my $cpan     = catfile( $ENV{HOME}, qw(.cpan sources modules), $packages );
my $cpanm    = catfile( $ENV{HOME}, qw(.cpanm sources) );
my $url      = 'http://www.cpan.org/modules/02packages.details.txt.gz';

my %o = qw(jobs 1);
GetOptions( \%o, qw(packages-file=s jobs=i) ) or pod2usage(1);

my $tmp = File::Temp->newdir();

my %known_packages;

sub load_packages_file {
    my ($fname) = @_;

    my $found_empty_line;
    ## open my $f, '<', $fname;
    my $f = IO::Zlib->new($fname, 'rb');
    while ( my $line = <$f> ) {
        chomp $line;
        if ($found_empty_line) {
            ## A1z::Html 0.04 C/CE/CEEJAY/A1z-Html-0.04.tar.gz
            my @fields = split /\s+/, $line;
            if ( @fields != 3 ) {
                confess "Unexpected format of line '$line'";
            }
            my ( $package, $version, $path ) = @fields;
            if ( exists $known_packages{$package} ) {
                confess "Package '$package' is already present";
            }

            my $root = $path;
            $root =~ s(^.+\/)();
            $root =~ s(-[^-]+$)();
            $root =~ s(-)(::)g;

            $known_packages{$package} = {
                version => $version,
                path    => $path,
                root    => $root,
            };
        }
        elsif ( $line eq '' ) {
            $found_empty_line = 1;
        }
    }
    close $f;
}

if ( $o{'packages-file'} && -e $o{'packages-file'} ) {
    load_packages_file( $o{'packages-file'} );
}
elsif ( -e $cpanm ) {
    for my $f ( glob catfile( $cpanm, '*', $packages ) ) {
        load_packages_file($f);
    }
}
elsif ( -e $cpan ) {
    load_packages_file($cpan);
}
else {
    my $f = catfile( tmpdir(), $packages );
    if ( ! -e $f ) {
        my $code = getstore( $url, $f );
        if ( $code < 200 || 300 <= $code ) {
            confess "Trying to download $url, got $code HTTP response code";
        }
    }
    load_packages_file($f);
}

my ( %deps, %local_modules );
my $scanner = Perl::PrereqScanner->new();

local $OUTPUT_AUTOFLUSH = 1;
pipe my $in, my $out;
my $jobs = 0;
$OSNAME eq 'MSWin32' || setpgrp;

sub process_file {
    my ($fname) = @_;

    my $s;
    {
        open my $f, '<', $fname;
        local $INPUT_RECORD_SEPARATOR;
        $s = <$f>;
        close $f;
        for my $module ( $s =~ /\bpackage\s+([^;]*);/g ) {
            $module =~ s/\s+//g;
            $local_modules{$module} = $fname;
        }
    }

    while ( $jobs >= $o{jobs} ) {
        while ( my $line = <$in> ) {
            chomp $line;
            if ( $line eq '' ) {
                last;
            }
            ++$deps{$line};
        }
        wait;
        --$jobs;
    }

    my $pid = fork;
    if ($pid) {
        ++$jobs;
        return;
    }

    close $in;

    my %modules;
    eval {
        %modules = map { $_ => 1 }
        grep { defined $_ && $_ ne 'perl' }
        $scanner->scan_string($s)->required_modules();
    };
    if ($@) {
        warn $@;
    }

    # use CORE::flock cause it fails on OSX
    CORE::flock $out, LOCK_EX;
    print $out join '', map { qq($_\n) } keys %modules;
    print $out qq(\n);
    CORE::flock $out, LOCK_UN;

    close $out;

    exit 0;
}

my @dirs = @ARGV;
if ( !@dirs ) {
    push @dirs, '.';
}
File::Find::find(
    {
        wanted => sub {
            if ( -d && /^(CVS|\.(svn|git))$/ ) {
                $File::Find::prune = 1;
                return;
            }
            elsif ( !/\.(pl|pm|t)$/ || -d ) {
                return;
            }
            process_file($File::Find::name);
        },
        no_chdir => 1,
    },
    @dirs
);

close $out;

while ($jobs) {
    while ( my $line = <$in> ) {
        chomp $line;
        if ( $line eq '' ) {
            last;
        }
        ++$deps{$line};
    }
    wait;
    --$jobs;
}

close $in;

sub file_name {
    my ($module) = @_;
    $module =~ s(::)(/)g;
    return "$module.pm";
}

sub apt_name {
    my ($module) = @_;

    $module eq 'Tk' and return 'perl-tk';

    my $apt = lc $module;
    $apt =~ s(::)(-)g;
    return "lib${apt}-perl";
}

sub port_name {
    my ($module) = @_;

    my $port = lc $module;
    $port =~ s(::)(-)g;
    return "p5-${port}";
}

my %modules;
for my $module (keys %deps) {
    exists $local_modules{$module} and next;
    defined module_path($module) and next;
    if (!exists $known_packages{$module}) {
        warn "Unknown root package for package '$module'";
        next;
    }
    my $root = $known_packages{$module}{root};
    $modules{$root} = {
        file => file_name($root),
        apt  => apt_name($root),
        port => port_name($root),
    };
}

if ( !%modules ) {
    exit 0;
}

if ( $OSNAME eq 'darwin' ) {
    my %port;

    my $re = join '|', map {"^$_->{port}\$"} values %modules;
    my $cmd = "port -q search --regex '$re'";
    for my $line (qx($cmd)) {
        chomp $line;
        if ( $line =~ /^(p5-\S+)$/ ) {
            $port{$1} = 1;

            while ( my ( $k, $v ) = each %modules ) {
                if ( $line =~ /^$v->{port}/ ) {
                    delete $modules{$k};
                }
            }
        }
    }

    my @port = sort { $a cmp $b } keys %port;
    if (@port) {
        my $mac_ports = join ' ', @port;
        print "# MacPorts\n";
        print "sudo port -N install $mac_ports\n";
        print qq(\n);
    }
}
elsif ( $OSNAME eq 'linux' ) {
    my %apt;

    # using apt-cache
    my $re = join '|', map {"^$_->{apt}\$"} values %modules;
    my $cmd = "apt-cache search '$re'";
    for my $line (qx($cmd)) {
        chomp $line;
        if ( $line =~ /^(lib\S+-perl|perl-\S+) - / ) {
            $apt{$1} = 1;

            while ( my ( $k, $v ) = each %modules ) {
                if ( $line =~ /^$v->{apt}/ ) {
                    delete $modules{$k};
                }
            }
        }
    }

    # # using apt-file
    # my $tmp = File::Temp->new();
    # $tmp->autoflush();
    # print $tmp map {"$_->{file}\n"} values %modules;

    # $cmd = 'apt-file -f search ' . $tmp->filename;
    # for my $line (qx($cmd)) {
    #     chomp $line;
    #     if ( $line =~ /^(lib\S+-perl|perl-\S+): / ) {
    #         $apt{$1} = 1;

    #         while ( my ( $k, $v ) = each %modules ) {
    #             ## NB: dangerous, can match multiple packages
    #             if ( $line =~ /$v->{file}$/ ) {
    #                 delete $modules{$k};
    #             }
    #         }
    #     }
    # }

    my @apt = sort { $a cmp $b } keys %apt;
    if (@apt) {
        my $apt_packages = join ' ', @apt;
        print "# aptitude\n";
        print "sudo apt-get -y install $apt_packages\n";
        print qq(\n);
    }
}

if (%modules) {
    my $cpan_modules = join ' ', sort { $a cmp $b } keys %modules;
    if (-e $cpanm) {
        print "# cpanm\n";
        print "cpanm $cpan_modules\n";
    }
    else {
        print "# cpan\n";
        print "PERL_MM_USE_DEFAULT=1 PERL_EXTUTILS_AUTOINSTALL=--defaultdeps cpan -i $cpan_modules\n";
    }
}
