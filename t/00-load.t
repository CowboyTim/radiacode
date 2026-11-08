use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/lib";
use RadiaTest qw(load_radiacode);

# Requiring the script must not run the CLI (it would exit without a device).
load_radiacode();
ok(defined &RadiaCode::BLE::new, 'RadiaCode::BLE loaded');
ok(defined &RadiaCode::BLE::decode_data_buf, 'decode_data_buf available');
ok(defined &RadiaCode::BLE::decode_spectrum, 'decode_spectrum available');
ok(defined &RadiaCode::BLE::monitor, 'monitor available');

done_testing;
