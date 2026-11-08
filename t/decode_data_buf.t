use strict;
use warnings;
use bytes;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use RadiaTest qw(load_radiacode);
load_radiacode();

my $base = 1000;
sub hdr { my ($seq, $eid, $gid, $ts) = @_; pack('C C C l<', $seq, $eid, $gid, $ts) }

subtest 'realtime record' => sub {
    my $data = hdr(5, 0, 0, 100) . pack('f<f<vvvC', 12.5, 0.25, 30, 40, 1, 2);
    my @r = RadiaCode::BLE::decode_data_buf($data, $base);
    is(scalar @r, 1, 'one record');
    is($r[0]{type}, 'realtime', 'type');
    is($r[0]{count_rate}, 12.5, 'count rate');
    is($r[0]{dose_rate}, 0.25, 'dose rate (raw)');
    is($r[0]{count_rate_err}, 3, 'count rate error is /10');
    is($r[0]{dose_rate_err}, 4, 'dose rate error is /10');
    is($r[0]{flags}, 1, 'flags');
    is($r[0]{rt_flags}, 2, 'rt flags');
    is($r[0]{time}, $base + 1, 'time = base + ts * 10 ms');
};

subtest 'event record carries a name' => sub {
    my $data = hdr(1, 0, 7, 0) . pack('CCv', 9, 3, 0);
    my ($e) = RadiaCode::BLE::decode_data_buf($data, $base);
    is($e->{type}, 'event', 'type');
    is($e->{event}, 9, 'event id');
    is($e->{event_name}, 'DOSE_RATE_ALARM1', 'event name');
    is($e->{event_param1}, 3, 'param');
    is(RadiaCode::BLE::event_name(999), 'EVENT_999', 'unknown id');
};

subtest 'mixed records, skipped groups keep the stream in sync' => sub {
    my $data = hdr(1, 0, 6, 0) . pack('vvv', 1, 2, 3)            # accel: consumed
             . hdr(2, 0, 1, 0) . pack('f<f<', 1, 2)               # raw
             . hdr(3, 1, 1, 0) . pack('v V', 2, 0) . ('x' x 16)   # spectrum block: skipped
             . hdr(4, 0, 3, 0) . pack('Vf<vvv', 7, 0.5, 2100, 9000, 0); # rare
    my @r = RadiaCode::BLE::decode_data_buf($data, $base);
    is(join(',', map { $_->{type} } @r), 'raw,rare', 'records in order, accel and block skipped');
    is($r[1]{temperature}, 1, 'rare temperature = (raw - 2000) / 100');
    is($r[1]{charge_level}, 90, 'rare charge = raw / 100');
};

subtest 'sequence gap stops decoding' => sub {
    my $data = hdr(9, 0, 0, 0) . pack('f<f<vvvC', 0, 0, 0, 0, 0, 0)
             . hdr(11, 0, 0, 0) . pack('f<f<vvvC', 0, 0, 0, 0, 0, 0);
    my @r = RadiaCode::BLE::decode_data_buf($data, $base);
    is(scalar @r, 1, 'only the first record before the gap');
};

subtest 'truncated record is not returned' => sub {
    my $data = hdr(1, 0, 0, 0) . pack('f<', 1.0);
    my @r = RadiaCode::BLE::decode_data_buf($data, $base);
    is(scalar @r, 0, 'no partial record');
};

done_testing;
