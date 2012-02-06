
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  "build_requires" => {
    "Devel::Peek" => 0,
    "File::Spec" => 0,
    "File::Temp" => 0,
    "Module::Build" => "0.3601",
    "Test::Fatal" => 0,
    "Test::More" => "0.88",
    "Tie::Array" => 0,
    "Tie::Hash" => 0,
    "base" => 0,
    "overload" => 0
  },
  "c_source" => "c",
  "configure_requires" => {
    "Module::Build" => "0.3601"
  },
  "dist_abstract" => "Validate method/function parameters",
  "dist_author" => [
    "Dave Rolsky, <autarch\@urth.org> and Ilya Martynov <ilya\@martynov.org>"
  ],
  "dist_name" => "Params-Validate",
  "dist_version" => "1.02",
  "license" => "artistic_2",
  "module_name" => "Params::Validate",
  "recommends" => {},
  "recursive_test_files" => 1,
  "requires" => {
    "Attribute::Handlers" => "0.79",
    "Carp" => 0,
    "Exporter" => 0,
    "Module::Runtime" => "0.011",
    "Package::Stash" => 0,
    "Scalar::Util" => "1.10",
    "Try::Tiny" => 0,
    "XSLoader" => 0,
    "attributes" => 0,
    "perl" => "5.008001",
    "strict" => 0,
    "vars" => 0,
    "warnings" => 0
  },
  "script_files" => []
);


my $build = Module::Build->new(%module_build_args);

my $skip_xs;
if ( grep { $_ eq '--pp' } @ARGV ) {
    $skip_xs = 1;
}
elsif ( ! can_xs() ) {
    $skip_xs = 1;
}

if ($skip_xs) {
    $build->build_elements(
        [ grep { $_ ne 'xs' } @{ $build->build_elements() } ] );
}

sub can_xs {
    # Do we have the configure_requires checker?
    local $@;
    eval "require ExtUtils::CBuilder;";
    if ($@) {

        # They don't obey configure_requires, so it is
        # someone old and delicate. Try to avoid hurting
        # them by falling back to an older simpler test.
        return can_cc();
    }

    # Do a simple compile that consumes the headers we need
    my @libs    = ();
    my $object  = undef;
    my $builder = ExtUtils::CBuilder->new( quiet => 1 );
    unless ( $builder->have_compiler ) {

        # Lack of a compiler at all
        return 0;
    }
    eval {
        $object = $builder->compile(
            source => 'sanexs.c',
        );
        @libs = $builder->link(
            objects     => $object,
            module_name => 'sanexs',
        );
    };
    my $broken = !!$@;
    foreach ( $object, @libs ) {
        next unless defined $_;
        1 while unlink $_;
    }

    if ($broken) {
        ### NOTE: Don't do this in a production release.
        # Compiler is officially screwed, you don't deserve
        # to do any of our downstream depedencies as you'll
        # probably end up choking on them as well.
        # Trigger an NA for their own protection.
        print "Unresolvable broken external dependency.\n";
        print "This package requires a C compiler with full perl headers.\n";
        print "Trivial test code using them failed to compile.\n";
        print STDERR "NA: Unable to build distribution on this platform.\n";
        exit(0);
    }

    return 1;
}

sub can_cc {
    my @chunks = split( / /, $Config::Config{cc} ) or return;

    # $Config{cc} may contain args; try to find out the program part
    while (@chunks) {
        return can_run("@chunks") || ( pop(@chunks), next );
    }

    return;
}

sub can_run {
    my ($cmd) = @_;

    my $_cmd = $cmd;
    if ( -x $_cmd or $_cmd = MM->maybe_command($_cmd) ) {
        return $_cmd;
    }

    foreach my $dir ( ( split /$Config::Config{path_sep}/, $ENV{PATH} ), '.' )
    {
        next if $dir eq '';
        my $abs = File::Spec->catfile( $dir, $cmd );
        return $abs if ( -x $abs or $abs = MM->maybe_command($abs) );
    }

    return;
}
$build->create_build_script;
