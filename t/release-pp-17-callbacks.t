

use Test::More;

BEGIN {
    unless ( $ENV{RELEASE_TESTING} ) {
        plan skip_all => 'these tests are for testing by the release';
    }

    $ENV{PERL_TEST_PV} = 1;
}

use strict;
use warnings;

use Params::Validate qw(validate validate_pos SCALAR);
use Test::More;

{
    my @p = ( foo => 1, bar => 2 );

    eval {
        validate(
            @p, {
                foo => {
                    type      => SCALAR,
                    callbacks => {
                        'bigger than bar' => sub { $_[0] > $_[1]->{bar} }
                    },
                },
                bar => { type => SCALAR },
            }
        );
    };

    like( $@, qr/bigger than bar/ );

    $p[1] = 3;
    eval {
        validate(
            @p, {
                foo => {
                    type      => SCALAR,
                    callbacks => {
                        'bigger than bar' => sub { $_[0] > $_[1]->{bar} }
                    },
                },
                bar => { type => SCALAR },
            }
        );
    };

    is( $@, q{} );
}

{
    my @p = ( 1, 2, 3 );
    eval {
        validate_pos(
            @p, {
                type      => SCALAR,
                callbacks => {
                    'bigger than [1]' => sub { $_[0] > $_[1]->[1] }
                }
            },
            { type => SCALAR },
            { type => SCALAR },
        );
    };

    like( $@, qr/bigger than \[1\]/ );

    $p[0] = 5;
    eval {
        validate_pos(
            @p, {
                type      => SCALAR,
                callbacks => {
                    'bigger than [1]' => sub { $_[0] > $_[1]->[1] }
                }
            },
            { type => SCALAR },
            { type => SCALAR },
        );
    };

    is( $@, q{} );
}

done_testing();
