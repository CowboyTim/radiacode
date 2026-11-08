use strict;
use warnings;
use bytes;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use RadiaTest qw(load_radiacode);
load_radiacode();

my $dc = \&RadiaCode::BLE::decode_counts_v1;
my $v0 = \&RadiaCode::BLE::decode_counts_v0;

subtest 'format v0: little-endian u32 counts' => sub {
    is_deeply([ $v0->(pack('V*', 1, 0, 70000)) ], [1, 0, 70000]);
};

subtest 'format v1: each delta width' => sub {
    # header = (count << 4) | vlen
    my $data = pack('v', (1 << 4) | 1) . pack('C', 200)            # vlen 1: absolute 200
             . pack('v', (1 << 4) | 2) . pack('c', -5)            # vlen 2: 200 - 5 = 195
             . pack('v', (1 << 4) | 3) . pack('s<', 1000)         # vlen 3: 195 + 1000 = 1195
             . pack('v', (1 << 4) | 4) . pack('CCc', 0x34, 0x12, 0) # vlen 4: 1195 + 0x1234 = 5855
             . pack('v', (1 << 4) | 5) . pack("l<", -5855)        # vlen 5: 5855 - 5855 = 0
             . pack('v', (2 << 4) | 0) ;                          # vlen 0: two zeros
    is_deeply([ $dc->($data) ], [200, 195, 1195, 5855, 0, 0, 0], 'deltas accumulate');
};

subtest 'format v1: negative 24-bit delta' => sub {
    my $data = pack('v', (1 << 4) | 1) . pack('C', 0x10)
             . pack('v', (1 << 4) | 4) . pack('CCc', 0x00, 0x00, -1);   # 16 + (-65536) = negative
    my @c = $dc->($data);
    is($c[1], 16 - 65536, 'signed high byte');
};

subtest 'format v1: unsupported width dies' => sub {
    my $data = pack('v', (1 << 4) | 7) . pack('C', 1);
    eval { $dc->($data) };
    like($@, qr/unsupported spectrum vlen=7/, 'dies with a clear message');
};

subtest 'format v1: truncated data dies' => sub {
    my $data = pack('v', (3 << 4) | 1) . pack('C', 1);    # claims 3 samples, has 1
    eval { $dc->($data) };
    like($@, qr/truncated spectrum/, 'truncated');
};

subtest 'decode_spectrum header and counts' => sub {
    my $blob = pack('V f< f< f<', 3600, 5.0, 2.0, 0.001) . pack('V*', 4, 0, 9);
    my $s = RadiaCode::BLE::decode_spectrum($blob, 0);
    is($s->{duration_s}, 3600, 'duration');
    is($s->{a1}, 2.0, 'a1');
    is_deeply($s->{counts}, [4, 0, 9], 'counts');
    is(RadiaCode::BLE::decode_spectrum('short', 0), undef, 'short blob rejected');
};

subtest 'channel to energy (quadratic)' => sub {
    is(RadiaCode::BLE::channel_to_keV(0, 5, 2, 0), 5, 'offset');
    is(RadiaCode::BLE::channel_to_keV(10, 5, 2, 0.5), 5 + 20 + 50, 'quadratic term');
};

done_testing;
