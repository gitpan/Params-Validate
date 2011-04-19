#!/usr/bin/perl -w

use Test::More;

BEGIN {
    unless ( $ENV{RELEASE_TESTING} ) {
        plan skip_all => 'these tests are for testing by the release';
    }

    $ENV{PERL_TEST_PV} = 1;
}


use strict;

use Params::Validate qw( validate validate_pos SCALAR );
use Test::More tests => 3;

{
    my @p = ( foo => 1, bar => 2 );

    eval {
        validate(
            @p, {
                foo => {
                    type      => SCALAR,
                    callbucks => {
                        'one' => sub {1}
                    },
                },
                bar => { type => SCALAR },
            }
        );
    };

    like( $@, qr/is not an allowed validation spec key/ );

    eval {
        validate(
            @p, {
                foo => {
                    hype      => SCALAR,
                    callbacks => {
                        'one' => sub {1}
                    },
                },
                bar => { type => SCALAR },
            }
        );
    };

    like( $@, qr/is not an allowed validation spec key/ );
    eval {
        validate(
            @p, {
                foo => {
                    type   => SCALAR,
                    regexp => qr/^\d+$/,
                },
                bar => { type => SCALAR },
            }
        );
    };

    like( $@, qr/is not an allowed validation spec key/ );
}

