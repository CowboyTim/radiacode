use strict;
use warnings;
use Test::More;
use FindBin;
use File::Spec;
use Pod::Checker;

my $script = File::Spec->catfile($FindBin::Bin, '..', 'radiacode.pl');

subtest 'POD is valid' => sub {
    my $checker = Pod::Checker->new(-warnings => 2);
    open my $null, '>', File::Spec->devnull or die $!;
    $checker->parse_from_file($script, $null);
    is($checker->num_errors, 0, 'no POD errors');
    is($checker->num_warnings, 0, 'no POD warnings');
};

subtest '--man prints the manual without a device' => sub {
    my $out = qx{$^X $script --man 2>&1};
    is($? >> 8, 0, 'exit status 0');
    like($out, qr/^NAME\s*$/m, 'has NAME section');
    like($out, qr/^SYNOPSIS\s*$/m, 'has SYNOPSIS section');
    like($out, qr/--monitor/, 'documents --monitor');
};

done_testing;
