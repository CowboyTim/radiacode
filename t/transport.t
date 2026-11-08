use strict;
use warnings;
use bytes;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use RadiaTest qw(load_radiacode fake_device);
load_radiacode();

# Build a response body for the given command, echoing the request header in the caller.
sub body { pack('V', 1) . pack('V', length $_[0]) . $_[0] }

subtest 'read_vs returns the string payload' => sub {
    my ($got) = fake_device(
        sub {
            my ($cmd, $seq, $args) = @_;
            return unless $cmd == 0x0826;             # RD_VIRT_STRING
            return body('HELLO');
        },
        sub { my ($d) = @_; $d->read_vs(0x0008) },
    );
    is($got, 'HELLO', 'payload');
};

subtest 'large response is reassembled from several notifications' => sub {
    my $big = join '', map { chr(65 + $_ % 26) } 1 .. 1000;
    my ($got) = fake_device(
        sub { body($big) },
        sub { my ($d) = @_; $d->read_vs(0x0100) },
    );
    is($got, $big, '1000 bytes across 20-byte notifications');
};

subtest 'batch read: only valid registers carry values' => sub {
    # Ask for 8 registers; the device flags bits 4 and 7 as valid and sends two values.
    my @vals = fake_device(
        sub {
            my ($cmd, $seq, $args) = @_;
            return unless $cmd == 0x082A;             # RD_VIRT_SFR_BATCH
            my $n = unpack('V', substr($args, 0, 4));
            is($n, 8, 'device sees 8 ids');
            return pack('V', 0x90) . pack('V', 1) . pack('V', 0x41C2E000);
        },
        sub {
            my ($d) = @_;
            $d->read_vsfrs_raw(0x8025, 0x8026, 0x8027, 0x8020, 0x0503, 0x8021, 0x8022, 0x8024);
        },
    );
    is(scalar @vals, 8, 'one entry per requested register');
    ok(!defined $vals[0] && !defined $vals[1] && !defined $vals[3], 'invalid registers are undef');
    is($vals[4], 1, 'DEVICE_ON valid');
    is($vals[7], 0x41C2E000, 'TEMP valid');
};

subtest 'execute: mismatched response header is rejected' => sub {
    my ($got) = fake_device(
        sub { my ($cmd, $seq) = @_; return 'x' },       # body is fine, but the header is
        sub {
            my ($d) = @_;
            # Replace the header echo: a device that answers with a different sequence number.
            local *RadiaCode::BLE::_read_response = sub { pack('v C C', 0x0826, 0, 0x7F) . 'body' };
            $d->execute(0x0826, '');
        },
    );
    ok(!defined $got, 'undef on header mismatch');
};

subtest 'empty body is defined (not failure)' => sub {
    my ($got) = fake_device(
        sub { '' },
        sub { my ($d) = @_; $d->execute(0x000B) },
    );
    is($got, '', 'empty string, defined');
};

subtest 'spectrum_delta: baseline, per-interval change, reset' => sub {
    my @blobs = (
        pack('V f< f< f<', 100, 0, 1, 0) . pack('V*', 5, 0, 10),   # baseline
        pack('V f< f< f<', 110, 0, 1, 0) . pack('V*', 7, 0, 10),   # +2 on channel 0
        pack('V f< f< f<', 5,   0, 1, 0) . pack('V*', 1, 0, 0),    # reset (duration and counts drop)
    );
    my $cfg = "SpecFormatVersion=0\n";
    my $n = 0;
    my ($text) = fake_device(
        sub {
            my ($cmd, $seq, $args) = @_;
            return unless $cmd == 0x0826;
            my $id = unpack('V', substr($args, 0, 4));
            return body($cfg)  if $id == 0x0002;      # configuration
            return body($blobs[$n++] // '') if $id == 0x0200;
            return;
        },
        sub {
            my ($d) = @_;
            my $out = '';
            open(my $fh, '>', \$out) or die;
            $d->spectrum_delta($fh) for 1 .. 3;
            close $fh;
            return $out;
        },
    );
    my @rows = grep { length } split /\n/, $text;
    is(scalar @rows, 1, 'only the changed channel is written');
    like($rows[0], qr/,0,0\.000,2$/, 'channel 0, energy and +2 counts');
};

done_testing;
