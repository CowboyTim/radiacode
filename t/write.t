use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use RadiaTest qw(load_radiacode);
load_radiacode();

my $enc = \&RadiaCode::BLE::encode_setting;
my $sv  = { cr_cpm => 0, ds_sv => 1 };
my $r   = { cr_cpm => 0, ds_sv => 0 };
my $cpm = { cr_cpm => 1, ds_sv => 1 };

is_deeply([ $enc->('brightness', 5) ], [0x0511, 5], 'brightness');
ok(!eval { $enc->('brightness', 10); 1 }, 'brightness above 9 refused');
is_deeply([ $enc->('display-off', 10) ], [0x0513, 1], 'display-off 10 s -> raw 1 (as read back)');
ok(!eval { $enc->('display-off', 20); 1 }, '20 s refused: shares raw 3 with 30 s');
is_deeply([ $enc->('display-off', 30) ], [0x0513, 3], 'display-off 30 s -> raw 3');
ok(!eval { $enc->('display-off', 12); 1 }, 'display-off 12 s refused');
is_deeply([ $enc->('direction', 'LEFT') ], [0x0515, 2], 'direction is case-insensitive');
is_deeply([ $enc->('direction', 'normal') ], [0x0515, 1], 'direction normal is raw 1');
is_deeply([ $enc->('backlight', 'on') ], [0x0516, 1], 'backlight on');
is_deeply([ $enc->('sound', 'off') ], [0x0522, 0], 'sound off');
is_deeply([ $enc->('vibration', 'on') ], [0x0531, 1], 'vibration on');
ok(!eval { $enc->('sound', 'maybe'); 1 }, 'on/off only');

is_deeply([ $enc->('alarm-count-1', 20, $r) ], [0x8008, 200], 'count alarm 20 cps -> 200');
is_deeply([ $enc->('alarm-count-2', 60, $r) ], [0x8009, 600], 'count alarm 60 cps -> 600');
is_deeply([ $enc->('alarm-count-1', 1200, $cpm) ], [0x8008, 200], '1200 cpm -> 20 cps -> 200');
ok(!eval { $enc->('alarm-count-1', 0.01, $r); 1 }, 'count alarm below 0.1 cps refused');

is_deeply([ $enc->('alarm-dose-rate-1', 0.4, $sv) ], [0x8000, 40], '0.4 uSv/h -> 40');
is_deeply([ $enc->('alarm-dose-rate-2', 1.2, $sv) ], [0x8001, 120], '1.2 uSv/h -> 120');
is_deeply([ $enc->('alarm-dose-rate-1', 40, $r) ], [0x8000, 40], 'R units: value is micro-R/h');

is_deeply([ $enc->('alarm-dose-1', 999.99, $sv) ], [0x8014, 99999], '999.99 uSv -> 99999 (matches device)');
is_deeply([ $enc->('alarm-dose-2', 999.99, $sv) ], [0x8015, 99999], 'dose alarm 2 likewise');
ok(!eval { $enc->('alarm-dose-1', 1e9, $sv); 1 }, 'value above the device maximum refused');
ok(!eval { $enc->('alarm-dose-1', -1, $sv); 1 }, 'negative refused');

ok(!eval { $enc->('no-such-setting', 1); 1 }, 'unknown name refused');
like($@, qr/unknown setting/, 'clear message');

is_deeply([ $enc->('alarm-mode', 'once') ], [0x05E0, 1], 'alarm mode once');
is_deeply([ $enc->('alarm-mode', 'continuous') ], [0x05E0, 0], 'alarm mode continuous');
ok(!eval { $enc->('alarm-mode', 'sometimes'); 1 }, 'alarm mode refused for other values');

done_testing;
