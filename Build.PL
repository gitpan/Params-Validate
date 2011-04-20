
use strict;
use warnings;

use Module::Build 0.3601;


my %module_build_args = (
  'build_requires' => {
    'Module::Build' => '0.3601',
    'Test::More' => '0.88'
  },
  'c_source' => 'c',
  'configure_requires' => {
    'Module::Build' => '0.3601'
  },
  'dist_abstract' => 'Validate method/function parameters',
  'dist_author' => [
    'Dave Rolsky, <autarch@urth.org> and Ilya Martynov <ilya@martynov.org>'
  ],
  'dist_name' => 'Params-Validate',
  'dist_version' => '0.97',
  'license' => 'artistic_2',
  'module_name' => 'Params::Validate',
  'recommends' => {},
  'recursive_test_files' => 1,
  'requires' => {
    'Attribute::Handlers' => '0.79',
    'Scalar::Util' => '1.10',
    'perl' => 'v5.8.1'
  },
  'script_files' => []
);


my $build = Module::Build->new(%module_build_args);

if ( grep { $_ eq '--pp' } @ARGV ) {
    $build->build_elements(
        [ grep { $_ ne 'xs' } @{ $build->build_elements() } ] );
}

$build->create_build_script;
