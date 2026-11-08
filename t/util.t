use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use RadiaTest qw(load_radiacode);
load_radiacode();

$ENV{TZ} = 'UTC';
POSIX::tzset();

subtest 'iso_time' => sub {
    is(RadiaCode::BLE::iso_time(1794162964.92), '2026-11-08T18:36:04.920+0000', 'UTC, millisecond part');
};

subtest 'csv_field quotes only when needed' => sub {
    is(RadiaCode::BLE::csv_field('plain'), 'plain', 'plain');
    is(RadiaCode::BLE::csv_field('a,b'), '"a,b"', 'comma quoted');
    is(RadiaCode::BLE::csv_field('say "hi"'), '"say ""hi"""', 'quotes doubled');
    is(RadiaCode::BLE::csv_field(undef), '', 'undef is empty');
};

subtest 'uuid byte order for ATT' => sub {
    is(unpack('H*', RadiaCode::BLE::uuid_le_bytes('e63215e6-7003-49d8-96b0-b024798fb901')),
       '01b98f7924b0b096d8490370e61532e6', 'reversed bytes');
};

subtest 'format_record names events' => sub {
    my $line = RadiaCode::BLE::format_record({ type => 'event', time => 0, event => 20,
        event_name => 'COUNT_RATE_ALARM1', event_param1 => 0 });
    like($line, qr/COUNT_RATE_ALARM1 \(id=20\)/, 'alarm name in text output');
};

done_testing;
