#!/usr/bin/perl -w

use Test::More;

BEGIN {
    unless ( $ENV{RELEASE_TESTING} ) {
        plan skip_all => 'these tests are for release testing';
    }

    $ENV{PV_TEST_PERL} = 1;
}


use strict;
use warnings;

use Test::More;

use Params::Validate qw( validate validate_pos SCALAR );

plan skip_all => 'Spec validation is disabled for now';

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

done_testing();

