use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use Time::Local qw(timegm);

# The analyser is a standalone script; loading it does not run it (main() is guarded).
require "$FindBin::Bin/../tools/rcspg-analyze.pl";

my $CAL = [5.349152, 2.3553936, 3.4938657e-4];

# A monitor-style spectrogram CSV: flat background plus one 140 keV line (channel 57),
# 60 intervals of 30 s, all inside 10:00-11:00 UTC on 2026-11-09.
my $dir = tempdir(CLEANUP => 1);
my $csv = "$dir/spectrogram-2026-11-09.csv";
my $t0  = timegm(0, 0, 10, 9, 10, 2026);
open(my $fh, '>', $csv) or die;
print {$fh} "time,a0,a1,a2," . join(',', map { "ch$_" } 0 .. 1023) . "\n";
for my $i (0 .. 59) {
    my @ch = map {
        my $bg = 20;
        my $pk = 400 * exp(-0.5 * (($_ - 57) / 2.5) ** 2);
        int($bg + $pk + 0.5);
    } 0 .. 1023;
    my @t = gmtime($t0 + 30 * $i);
    my $iso = sprintf('%04d-%02d-%02dT%02d:%02d:%02d.000+0000',
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    print {$fh} join(',', $iso, @$CAL, @ch) . "\n";
}
close $fh;

my $recs = RadiaCode::Analyze::read_input($csv);
is(scalar @$recs, 60, 'all 60 CSV rows read');
is($recs->[0]{t}, $t0, 'first row time');
is($recs->[5]{dt}, 30, 'interval from the row spacing');

my $reg = RadiaCode::Analyze::make_spectrum($recs);
is($reg->{records}, 60, 'region has all records');
is_deeply($reg->{calib}, $CAL, 'calibration taken from the rows');

my ($net, $var) = RadiaCode::Analyze::net_spectrum($reg, undef);
my $peaks = RadiaCode::Analyze::find_peaks($net, $var, $reg->{calib}, $reg->{seconds}, 4);
ok(@$peaks >= 1, 'a peak is found');
my ($top) = sort { $b->{sigma} <=> $a->{sigma} } @$peaks;
ok(abs($top->{energy} - 140) < 3, 'strongest peak is near 140 keV')
    or diag("peak at $top->{energy} keV");

my ($lines, $notes) = RadiaCode::Analyze::load_lines(
    mode => 'builtin', nuclides => [ [ '99tc', 'Tc-99m' ], [ 'am241', 'Am-241' ] ],
    cache_dir => $dir, min_I => 3,
);
my ($g, $off) = RadiaCode::Analyze::best_calibration(
    [ map { @$_ } values %$lines ], $peaks, 2, 0.02, 3);
my $cpeaks = RadiaCode::Analyze::corrected_peaks($peaks, $g, $off);
my @ranked = RadiaCode::Analyze::score_nuclides($lines, $cpeaks, 2, 0.02);
is($ranked[0]{nuc}, 'Tc-99m', 'the 140 keV line ranks Tc-99m first');
is($ranked[0]{matched}, 1, 'and its one library line is matched');
my ($am) = grep { $_->{nuc} eq 'Am-241' } @ranked;
is($am->{matched}, 0, 'Am-241 (59.5 keV) is not seen, as there is no peak there');
ok(!$am->{strongest_seen}, 'Am-241 strongest line is reported as not seen');

is(RadiaCode::Analyze::parse_local_time('2026-11-09 11:00', '+0100'),
   timegm(0, 0, 10, 9, 10, 2026), 'local time with +0100 converted to UTC');
is(RadiaCode::Analyze::parse_local_time('2026-11-09 10:00', ''),
   timegm(0, 0, 10, 9, 10, 2026), 'no zone means UTC');

# Extracted .rcspg text: header, Spectrum line with the calibration, FILETIME rows.
my $rc = "$dir/test.rcspg";
my $blob = pack('V f< f< f<', 1000, @$CAL) . ("\0" x 8);
open(my $r, '>', $rc) or die;
print {$r} "Spectrogram: test\tTime: 2026-11-09 11:00:00\n";
print {$r} "Spectrum: " . join(' ', map { sprintf '%02X', ord } split //, $blob) . "\n";
my $ft = ($t0 + 11644473600) * 10_000_000;
for my $i (0 .. 2) {
    my @ch = (1) x 1024;
    print {$r} join("\t", $ft + $i * 300_000_000, 0, @ch) . "\n";
}
close $r;
my $rrecs = RadiaCode::Analyze::read_input($rc);
is(scalar @$rrecs, 3, 'rcspg rows read');
is($rrecs->[0]{t}, $t0, 'FILETIME converted to Unix time');
ok(abs($rrecs->[0]{calib}[2] - $CAL->[2]) < 1e-9, "calibration from the Spectrum line");
is($rrecs->[0]{counts}, 1024, 'counts summed over channels');

done_testing;
