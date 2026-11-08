use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/lib";
use RadiaTest qw(load_radiacode);
load_radiacode();

my $dir = tempdir(CLEANUP => 1);
open(my $r, '>', "$dir/rates.csv") or die;
print {$r} "time,cps,cpm,cps_err_pct,dose_rate_uSv_h,dose_rate_raw,flags\n";
print {$r} "2026-11-08T18:00:00.000+0000,14,840,4.8,0.08,8e-06,0\n";
print {$r} "2026-11-08T18:01:00.000+0000,15,900,4.7,0.09,9e-06,0\n";
close $r;
open(my $e, '>', "$dir/events.csv") or die;
print {$e} "time,event_id,event_name,param1,flags\n";
print {$e} "2026-11-08T18:00:30.000+0000,20,COUNT_RATE_ALARM1,0,0\n";
close $e;
open(my $s, '>', "$dir/spectrum.csv") or die;
print {$s} "time,channel,energy_keV,counts\n";
print {$s} "2026-11-08T18:00:10.000+0000,3,12.4,2\n";
print {$s} "2026-11-08T18:00:20.000+0000,5,20.1,7\n";
close $s;

is(RadiaCode::Plot::run($dir), 0, 'plot returns 0');
ok(-s "$dir/rates.svg", 'rates.svg written');
ok(-s "$dir/spectrum.svg", 'spectrum.svg written');

open(my $f, '<', "$dir/rates.svg") or die;
my $svg = do { local $/; <$f> };
like($svg, qr/COUNT_RATE_ALARM1/, 'alarm event marked on the rates plot');
like($svg, qr/<svg /, 'rates.svg is an svg');

done_testing;
