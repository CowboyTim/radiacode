use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/lib";
use RadiaTest qw(load_radiacode);
load_radiacode();

my $dir = tempdir(CLEANUP => 1);

subtest 'one set of dated files per day, each with a header' => sub {
    my $fh = RadiaCode::BLE::_open_day($dir, '2026-11-08', 1);
    print {$fh->{rates}} "2026-11-08T10:00:00.000+0000,15,900,4.7,0.09,9e-06,0\n";
    close $_ for values %$fh;
    ok(-f "$dir/rates-2026-11-08.csv", 'rates file named by date');
    ok(-f "$dir/events-2026-11-08.csv", 'events file named by date');
    ok(-f "$dir/spectrogram-2026-11-08.csv", 'spectrogram file named by date');
    open(my $in, '<', "$dir/rates-2026-11-08.csv") or die;
    my $first = <$in>;
    is($first, "time,cps,cpm,cps_err_pct,dose_rate_uSv_h,dose_rate_raw,flags\n", 'header first');
};

subtest 'reopening the same day appends without a second header' => sub {
    my $fh = RadiaCode::BLE::_open_day($dir, '2026-11-08', 0);
    print {$fh->{rates}} "2026-11-08T10:00:02.000+0000,16,960,4.6,0.10,1e-05,0\n";
    close $_ for values %$fh;
    open(my $in, '<', "$dir/rates-2026-11-08.csv") or die;
    my @lines = <$in>;
    is(scalar(grep { /^time,/ } @lines), 1, 'one header');
    is(scalar @lines, 3, 'header + two data rows');
};

subtest 'plot reads every day of a kind, in date order' => sub {
    RadiaCode::BLE::_open_day($dir, '2026-11-09', 0);
    open(my $o, '>', "$dir/rates-2026-11-09.csv") or die;
    print {$o} "time,cps,cpm,cps_err_pct,dose_rate_uSv_h,dose_rate_raw,flags\n";
    print {$o} "2026-11-09T09:00:00.000+0000,12,720,5.0,0.07,7e-06,0\n";
    close $o;
    my $rows = RadiaCode::Plot::read_logs($dir, 'rates');
    is(scalar @$rows, 3, 'rows from both days');
    is($rows->[0]{time}, '2026-11-08T10:00:00.000+0000', 'earliest first');
    is($rows->[-1]{time}, '2026-11-09T09:00:00.000+0000', 'latest last');
};

done_testing;
