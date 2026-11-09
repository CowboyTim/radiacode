#!/usr/bin/env perl
# rcspg-analyze.pl - analyse RadiaCode spectrogram recordings.
#
# Input is any of:
#   * a RadiaCode app export (.zrcspg: a zip holding a .rcspg text file)
#   * an extracted .rcspg text file
#   * a spectrogram-DATE.csv written by radiacode.pl --monitor
#
# It reports the count rate over time, the energy spectrum of a time window (optionally
# net of a reference window), the peaks in that spectrum, and which known gamma lines
# they match. Known lines come from the IAEA LiveChart decay data (ENSDF, fetched with
# curl and cached) or from a small built-in table when the lookup is not possible.
# With --svg the spectrum is drawn with the matched lines marked on it.
#
# Core Perl modules only. Reading a .zrcspg needs the `unzip` program; --lines online
# (the default when available) needs `curl`.
#
# Usage: rcspg-analyze.pl FILE [options]     (see --help)

use strict;
use warnings;

package RadiaCode::Analyze;
use Getopt::Long qw(GetOptionsFromArray);
use File::Path qw(make_path);
use File::Spec;
use List::Util qw(sum0);
use Scalar::Util qw(looks_like_number);
use Time::Local qw(timegm);

use constant FILETIME_EPOCH_OFFSET => 11644473600;   # seconds 1601-01-01 -> 1970-01-01
use constant NCH                   => 1024;
use constant MAX_GAP_S             => 900;           # longer gaps are not counted as time

# Gamma lines used when the online lookup is off or fails. Energies in keV, intensities in
# % of decays. Approximate values from standard decay data; --lines online uses ENSDF.
my %BUILTIN_LINES = (
    'Am-241' => [ [59.54, 35.9], [26.34, 2.27] ],
    'Tc-99m' => [ [140.51, 89.0] ],
    'Tl-201' => [ [135.34, 2.6], [167.43, 10.0] ],
    'I-123'  => [ [158.97, 83.3] ],
    'I-131'  => [ [80.18, 2.6], [284.30, 6.1], [364.49, 81.5], [637.0, 7.2] ],
    'In-111' => [ [171.28, 90.2], [245.35, 94.1] ],
    'Ga-67'  => [ [93.31, 38.8], [184.58, 21.2], [300.22, 16.6], [393.53, 4.6] ],
    'Co-57'  => [ [122.06, 85.6], [136.47, 10.7] ],
    'Ba-133' => [ [80.99, 32.9], [276.40, 7.2], [302.85, 18.3], [356.01, 62.0] ],
    'Cs-137' => [ [661.66, 85.1] ],
    'Co-60'  => [ [1173.23, 99.9], [1332.49, 100] ],
    'Na-22'  => [ [1274.54, 99.9] ],
    'Xe-133' => [ [80.99, 37.0] ],
    'Lu-177' => [ [113.0, 6.4], [208.37, 10.4] ],
    'Eu-152' => [ [121.78, 28.5], [344.28, 26.6], [778.90, 12.9], [1408.01, 21.0] ],
    'K-40'   => [ [1460.82, 10.7] ],
    'Ra-226' => [ [186.21, 3.6] ],
    'F-18'   => [ [511.0, 193.0] ],
);

# [IAEA nuclide query name, label]
my @NUCLIDES = (
    [ 'am241', 'Am-241' ], [ '99tc', 'Tc-99m' ],  [ '201tl', 'Tl-201' ], [ '123i', 'I-123' ],
    [ '131i',  'I-131' ],  [ '111in', 'In-111' ], [ '67ga', 'Ga-67' ],  [ '57co', 'Co-57' ],
    [ '133ba', 'Ba-133' ], [ '137cs', 'Cs-137' ], [ '60co', 'Co-60' ], [ '22na', 'Na-22' ],
    [ '133xe', 'Xe-133' ], [ '177lu', 'Lu-177' ], [ '152eu', 'Eu-152' ], [ '40k', 'K-40' ],
    [ '226ra', 'Ra-226' ], [ '18f', 'F-18' ],
);

sub default_cache_dir {
    my $base = $ENV{XDG_CACHE_HOME} || File::Spec->catdir($ENV{HOME} // '.', '.cache');
    return File::Spec->catdir($base, 'radiacode-perl');
}

# ============================================================================
# Reading the recordings
# ============================================================================

# "+HHMM" / "-HH:MM" -> seconds east of UTC
sub tz_seconds {
    my ($o) = @_;
    return 0 unless defined $o && length $o;
    my ($sign, $h, $m) = $o =~ /^([+-])(\d\d):?(\d\d)$/ or die "bad --tz value: $o\n";
    my $s = $h * 3600 + $m * 60;
    return $sign eq '-' ? -$s : $s;
}

# "YYYY-MM-DD HH:MM[:SS]" written in the offset zone -> epoch seconds
sub parse_local_time {
    my ($s, $tz) = @_;
    my @m = $s =~ /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d)(?::(\d\d))?$/
        or die "bad time (want YYYY-MM-DD HH:MM[:SS]): $s\n";
    return timegm($m[5] // 0, $m[4], $m[3], $m[2], $m[1] - 1, $m[0]) - tz_seconds($tz);
}

# "YYYY-MM-DDTHH:MM:SS.mmm+HHMM" (the monitor CSV format) -> epoch seconds
sub parse_iso_time {
    my ($s) = @_;
    my @m = $s =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?([+-])(\d\d):?(\d\d)$/
        or return undef;
    my ($y, $mo, $d, $h, $mi, $se, $frac, $sign, $oh, $om) = @m;
    my $off = ($oh * 3600 + $om * 60) * ($sign eq '-' ? -1 : 1);
    return timegm($se, $mi, $h, $d, $mo - 1, $y) - $off + ($frac ? "0.$frac" : 0);
}

sub fmt_utc {
    my ($e) = @_;
    my @g = gmtime(int($e));
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d', $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]);
}

sub median {
    my @s = sort { $a <=> $b } @_;
    return 1 unless @s;
    return $s[int($#s / 2)];
}

# Read the whole input (zip, .rcspg or CSV) and return the records, sorted by time:
#   { t => epoch, calib => [a0,a1,a2], counts => total, ch => [1024 ints], dt => seconds }
# dt is the time the record covers, taken from the gap to the previous record.
sub read_input {
    my ($file) = @_;
    die "no such file: $file\n" unless -f $file;
    open(my $probe, '<:raw', $file) or die "cannot read $file: $!\n";
    read($probe, my $magic, 2);
    close $probe;

    my $text;
    if (defined $magic && $magic eq 'PK') {
        $text = _read_zip_member($file);
    } else {
        open(my $fh, '<:raw', $file) or die "cannot read $file: $!\n";
        local $/;
        $text = <$fh>;
        close $fh;
    }
    my @lines = split /\n/, $text;
    my @recs = $lines[0] =~ /^Spectrogram:/ ? _parse_rcspg(\@lines)
             : $lines[0] =~ /^time,/        ? _parse_csv(\@lines)
             : die "$file: not a .zrcspg, .rcspg or spectrogram CSV\n";
    die "$file: no spectrogram rows found\n" unless @recs;

    @recs = sort { $a->{t} <=> $b->{t} } @recs;
    my @gaps;
    for my $i (1 .. $#recs) {
        my $dt = $recs[$i]{t} - $recs[ $i - 1 ]{t};
        push @gaps, $dt if $dt > 0 && $dt <= MAX_GAP_S;
    }
    my $typical = median(@gaps);
    for my $i (0 .. $#recs) {
        my $dt = $i ? $recs[$i]{t} - $recs[ $i - 1 ]{t} : $typical;
        $dt = $typical if $dt <= 0 || $dt > MAX_GAP_S;
        $recs[$i]{dt} = $dt;
    }
    return \@recs;
}

# Return the text of the first .rcspg (or .csv) member of a zip file, using unzip(1).
sub _read_zip_member {
    my ($file) = @_;
    open(my $ls, '-|', 'unzip', '-Z1', $file)
        or die "cannot run unzip (needed to read a .zrcspg): $!\n";
    my @names = <$ls>;
    close $ls;
    chomp @names;
    my ($member) = grep { /\.rcspg$/i } @names;
    ($member) = grep { /\.csv$/i } @names unless defined $member;
    die "no .rcspg or .csv inside $file\n" unless defined $member;

    open(my $fh, '-|', 'unzip', '-p', $file, $member)
        or die "cannot run unzip: $!\n";
    local $/;
    my $text = <$fh>;
    close $fh or die "unzip failed reading $member from $file\n";
    return $text;
}

sub _parse_rcspg {
    my ($lines) = @_;
    my @calib;
    for my $l (@$lines) {
        next unless $l =~ /^Spectrum:\s*([0-9A-Fa-f ]+)/;
        (my $hex = $1) =~ s/\s+//g;
        # The blob starts with its duration (u32) and the calibration a0, a1, a2 (floats).
        (undef, @calib) = unpack('V f< f< f<', pack('H*', substr($hex, 0, 32)));
        last;
    }
    my @recs;
    for my $l (@$lines) {
        next unless $l =~ /^\d+\t/;
        my @f = split /\t/, $l, -1;
        next unless @f == NCH + 2;
        my @ch = map { 0 + $_ } @f[ 2 .. NCH + 1 ];
        push @recs, {
            t      => int($f[0] / 1e7) - FILETIME_EPOCH_OFFSET,
            calib  => [@calib],
            counts => sum0(@ch),
            ch     => \@ch,
        };
    }
    die "no calibration (Spectrum: line) in .rcspg, use --calib\n" unless @calib || !@recs;
    return @recs;
}

sub _parse_csv {
    my ($lines) = @_;
    my @cols = split /,/, shift @$lines;
    my %idx;
    @idx{@cols} = (0 .. $#cols);
    my @ch_idx = map { $idx{"ch$_"} } 0 .. NCH - 1;
    my @recs;
    for my $l (@$lines) {
        next unless length $l;
        my @f = split /,/, $l, -1;
        my $t = parse_iso_time($f[ $idx{time} ]);
        next unless defined $t;
        my @ch = map { 0 + ($f[$_] // 0) } @ch_idx;
        push @recs, {
            t      => $t,
            calib  => [ map { 0 + $f[ $idx{$_} ] } qw(a0 a1 a2) ],
            counts => sum0(@ch),
            ch     => \@ch,
        };
    }
    return @recs;
}

# Records with t in [from, to); undef bounds are open.
sub select_records {
    my ($recs, $from, $to) = @_;
    return [ grep {
        (!defined $from || $_->{t} >= $from) && (!defined $to || $_->{t} < $to)
    } @$recs ];
}

# Sum the channels and time of a set of records.
sub make_spectrum {
    my ($recs) = @_;
    die "no spectrogram rows in the selected window\n" unless @$recs;
    my @n = (0) x NCH;
    my $secs = 0;
    for my $r (@$recs) {
        my $ch = $r->{ch};
        $n[$_] += $ch->[$_] for 0 .. NCH - 1;
        $secs += $r->{dt};
    }
    return { counts => \@n, seconds => $secs, calib => $recs->[0]{calib}, records => scalar @$recs };
}

sub channel_energy {
    my ($c, $cal) = @_;
    my ($a0, $a1, $a2) = @$cal;
    return $a0 + $a1 * $c + $a2 * $c * $c;
}

# Count rate per time bin (bin is in minutes).
sub rate_bins {
    my ($recs, $bin_min) = @_;
    my %bins;
    for my $r (@$recs) {
        my $k = int($r->{t} / ($bin_min * 60));
        my $b = $bins{$k} //= { t => $k * $bin_min * 60, records => 0, counts => 0, seconds => 0 };
        $b->{records}++;
        $b->{counts}  += $r->{counts};
        $b->{seconds} += $r->{dt};
    }
    return [ map { $bins{$_} } sort { $a <=> $b } keys %bins ];
}

# ============================================================================
# Peaks and matching
# ============================================================================

# Net counts per channel (region minus reference scaled to the same time) and their variance.
sub net_spectrum {
    my ($reg, $ref) = @_;
    my $k = $ref ? $reg->{seconds} / $ref->{seconds} : 0;
    my (@net, @var);
    for my $c (0 .. NCH - 1) {
        my $n = $reg->{counts}[$c];
        my $q = $ref ? $ref->{counts}[$c] * $k : 0;
        $net[$c] = $n - $q;
        $var[$c] = $n + ($ref ? $ref->{counts}[$c] * $k * $k : 0);
    }
    return (\@net, \@var);
}

# Local maxima of the 3-channel sums that stand out from the surrounding continuum.
# sigma is approximate (Poisson on the peak sum plus the background).
sub find_peaks {
    my ($net, $var, $cal, $seconds, $min_sigma) = @_;
    my (@S, @V);
    for my $c (1 .. NCH - 2) {
        $S[$c] = $net->[$c - 1] + $net->[$c] + $net->[ $c + 1 ];
        $V[$c] = $var->[$c - 1] + $var->[$c] + $var->[ $c + 1 ];
    }
    my @peaks;
    for my $c (7 .. NCH - 8) {
        my $s = $S[$c];
        next if grep { $S[ $c + $_ ] > $s } -2 .. -1, 1 .. 2;
        my $bg = sum0(@S[ $c - 6 .. $c - 3 ], @S[ $c + 3 .. $c + 6 ]) / 8;
        my $signal = $s - $bg;
        next unless $signal > 0;
        my $var_pk = $V[$c] + ($bg > 0 ? $bg : 0);
        my $sigma  = $var_pk > 0 ? $signal / sqrt($var_pk) : 0;
        next unless $sigma >= $min_sigma;
        push @peaks, {
            channel => $c,
            energy  => channel_energy($c, $cal),
            cps     => $signal / $seconds,
            sigma   => $sigma,
        };
    }
    return \@peaks;
}

sub tol_for {
    my ($energy, $abs_tol, $rel_tol) = @_;
    my $rel = $energy * $rel_tol;
    return $rel > $abs_tol ? $rel : $abs_tol;
}

# Best offset for the device energies: keV_true = keV_device + offset, with the offset within
# +/-$max_shift keV. The gain is kept at 1: fitting a gain as well overfits a few peaks, since
# it can line almost any peak up with some strong library line. Each peak scores its
# significance times the intensity of the library line it lands on; ties go to the smaller
# offset. Returns (gain, offset, score), with gain always 1.
sub best_calibration {
    my ($lines, $peaks, $abs_tol, $rel_tol, $max_shift) = @_;
    my ($best_s, $best_score) = (0, -1);
    for (my $s = -$max_shift; $s <= $max_shift + 1e-9; $s += 0.25) {
        my $score = 0;
        for my $p (@$peaks) {
            # The strongest library line within tolerance counts for this peak.
            my $e = $p->{energy} + $s;
            my $best_I = 0;
            for my $L (@$lines) {
                next unless abs($L->{E} - $e) <= tol_for($L->{E}, $abs_tol, $rel_tol);
                $best_I = $L->{I} if $L->{I} > $best_I;
            }
            $score += $p->{sigma} * $best_I / 100;
        }
        if ($score > $best_score + 1e-9
            || (abs($score - $best_score) <= 1e-9 && abs($s) < abs($best_s))) {
            ($best_s, $best_score) = ($s, $score);
        }
    }
    return (1, $best_s, $best_score);
}

# Peaks moved onto the library energy scale by a calibration pair from best_calibration.
sub corrected_peaks {
    my ($peaks, $g, $s) = @_;
    return [ map { +{ %$_, energy => $g * $_->{energy} + $s } } @$peaks ];
}


# One row per nuclide: the share of its library gamma intensity that has a peak
# at the library energy (peaks already corrected).
sub score_nuclides {
    my ($lines_by_nuc, $peaks, $abs_tol, $rel_tol) = @_;
    my @out;
    for my $nuc (sort keys %$lines_by_nuc) {
        my @L = @{ $lines_by_nuc->{$nuc} };
        next unless @L;
        my ($strongest) = sort { $b->{I} <=> $a->{I} } @L;
        my ($all, $got, $nmatch, $strongest_seen) = (0, 0, 0, 0);
        for my $L (@L) {
            $all += $L->{I};
            my $tol = tol_for($L->{E}, $abs_tol, $rel_tol);
            my $hit = grep { abs($_->{energy} - $L->{E}) <= $tol } @$peaks;
            next unless $hit;
            $got += $L->{I};
            $nmatch++;
            $strongest_seen = 1 if $L == $strongest;
        }
        push @out, {
            nuc => $nuc, lines => scalar @L, matched => $nmatch, got => $got,
            frac => $all ? $got / $all : 0,
            strongest => $strongest, strongest_seen => $strongest_seen,
        };
    }
    return sort { $b->{got} <=> $a->{got} || $a->{nuc} cmp $b->{nuc} } @out;
}

# ============================================================================
# Gamma line libraries
# ============================================================================

# Parse the IAEA decay_rads CSV into [energy, intensity] pairs, one per energy.
sub _parse_decay_rads {
    my ($text) = @_;
    my @lines = split /\n/, $text;
    my @cols  = split /,/, shift @lines;
    my %idx;
    @idx{@cols} = (0 .. $#cols);
    return [] unless defined $idx{energy} && defined $idx{intensity};
    my %best;
    for my $l (@lines) {
        my @f = split /,/, $l, -1;
        my ($e, $i) = @f[ $idx{energy}, $idx{intensity} ];
        next unless defined $e && defined $i;
        next unless looks_like_number($e) && looks_like_number($i) && $i > 0;
        my $key = sprintf('%.2f', $e);
        $best{$key} = [ 0 + $e, 0 + $i ] if !$best{$key} || $i > $best{$key}[1];
    }
    return [ values %best ];
}

# Fetch the gamma lines of one nuclide from IAEA LiveChart; cached in $cache_dir.
sub fetch_online_lines {
    my ($query, $cache_dir) = @_;
    my $cache = File::Spec->catfile($cache_dir, "$query.decay_rads.csv");
    my $text;
    if (-s $cache) {
        open(my $fh, '<', $cache) or return;
        local $/;
        $text = <$fh>;
        close $fh;
    } else {
        my $url = "https://nds.iaea.org/relnsd/v0/data?fields=decay_rads&nuclides=$query&rad_types=g";
        open(my $p, '-|', 'curl', '-fsS', '-m', '30', $url) or return;
        local $/;
        $text = <$p>;
        close($p) or return;
        return unless defined $text && $text =~ /^energy,/m;
        make_path($cache_dir);
        if (open(my $out, '>', $cache)) { print {$out} $text; close $out }
    }
    return unless defined $text && $text =~ /^energy,/m;
    return _parse_decay_rads($text);
}

# Returns { label => [ {E, I, nuc}, ... ] } and a list of notes about where lines came from.
sub load_lines {
    my (%opt) = @_;   # mode, nuclides, cache_dir, min_I
    my (%lines, @notes);
    for my $n (@{ $opt{nuclides} }) {
        my ($query, $label) = @$n;
        my $pairs;
        if ($opt{mode} ne 'builtin') {
            $pairs = fetch_online_lines($query, $opt{cache_dir});
            if (!$pairs || !@$pairs) {
                push @notes, "$label: online lookup failed" if $opt{mode} eq "auto";
                $pairs = undef;
            }
        }
        if (!$pairs && $opt{mode} ne 'online' && $BUILTIN_LINES{$label}) {
            $pairs = $BUILTIN_LINES{$label};
            push @notes, "$label: online lookup unavailable, built-in line table used" if $opt{mode} eq "auto";
        }
        next unless $pairs && @$pairs;
        for my $p (@$pairs) {
            my ($E, $I) = @$p;
            next unless $I >= $opt{min_I} && $E >= 20 && $E <= 3000;
            push @{ $lines{$label} }, { E => $E, I => $I, nuc => $label };
        }
    }
    return (\%lines, \@notes);
}

# ============================================================================
# Output
# ============================================================================

sub write_csv {
    my ($file, $reg, $net) = @_;
    open(my $fh, '>', $file) or die "cannot write $file: $!\n";
    print {$fh} "channel,keV,counts,cps,net_cps\n";
    for my $c (0 .. NCH - 1) {
        printf {$fh} "%d,%.3f,%d,%.6g,%.6g\n", $c, channel_energy($c, $reg->{calib}),
            $reg->{counts}[$c], $reg->{counts}[$c] / $reg->{seconds}, $net->[$c] / $reg->{seconds};
    }
    close $fh or die "cannot write $file: $!\n";
}

sub _esc {
    my ($s) = @_;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    return $s;
}

# Channel for a device energy: inverse of keV = a0 + a1*ch + a2*ch^2 (rising branch).
sub channel_for_energy {
    my ($E, $cal) = @_;
    my ($a0, $a1, $a2) = @$cal;
    return ($E - $a0) / $a1 if abs($a2) < 1e-12;
    my $disc = $a1 * $a1 - 4 * $a2 * ($a0 - $E);
    return undef if $disc < 0;
    return (-$a1 + sqrt($disc)) / (2 * $a2);
}

# Spectrum as a histogram: channel on the x axis, log10 counts/s on the y axis. Each channel
# is a vertical line from the bottom of the plot up to its value. Matched library lines are
# dashed marks at their channel, labelled with the energy.
sub write_svg {
    my ($file, $reg, $net, $emax, $marks) = @_;
    my ($W, $H, $L, $R, $T, $B) = (960, 420, 70, 20, 30, 56);
    my $pw = $W - $L - $R;
    my $ph = $H - $T - $B;
    my $cal = $reg->{calib};

    my $cmax = channel_for_energy($emax, $cal);
    $cmax = NCH - 1 if !defined $cmax || $cmax > NCH - 1;
    $cmax = int($cmax);

    my @v;
    my $vmax = 0;
    for my $c (0 .. $cmax) {
        my $v = $net->[$c] / $reg->{seconds};
        push @v, $v;
        $vmax = $v if $v > $vmax;
    }
    $vmax = 1 unless $vmax > 0;
    my $lmax = log($vmax) / log(10);
    my $lmin = $lmax - 4;                      # four decades shown
    my $x = sub { $L + $pw * ($_[0]) / ($cmax + 1) };
    my $y = sub {
        my $lv = log(max_of($_[0], 10 ** $lmin)) / log(10);
        return $T + $ph * ($lmax - $lv) / ($lmax - $lmin);
    };

    open(my $fh, '>', $file) or die "cannot write $file: $!\n";
    print {$fh} qq{<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" viewBox="0 0 $W $H" font-family="sans-serif" font-size="11">\n};
    print {$fh} qq{<rect width="100%" height="100%" fill="#ffffff"/>\n};

    # decade grid and y labels
    for (my $k = ceil_int($lmin); $k <= floor_int($lmax); $k++) {
        my $yy = $T + $ph * ($lmax - $k) / ($lmax - $lmin);
        printf {$fh} qq{<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#e3e3e3"/>\n}, $L, $yy, $L + $pw, $yy;
        printf {$fh} qq{<text x="%.1f" y="%.1f" text-anchor="end" fill="#333">%g</text>\n}, $L - 6, $yy + 4, 10 ** $k;
    }
    printf {$fh} qq{<text x="14" y="%.1f" fill="#333" transform="rotate(-90 14 %.1f)" text-anchor="middle">net counts/s (log)</text>\n}, $T + $ph / 2, $T + $ph / 2;

    # axes and channel ticks (with the energy of each tick below it)
    printf {$fh} qq{<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#333"/>\n}, $L, $T + $ph, $L + $pw, $T + $ph;
    printf {$fh} qq{<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="#333"/>\n}, $L, $T, $L, $T + $ph;
    my $step = $cmax <= 300 ? 25 : $cmax <= 700 ? 50 : 100;
    for (my $c = 0; $c <= $cmax; $c += $step) {
        my $xx = $x->($c);
        printf {$fh} qq{<text x="%.1f" y="%.1f" text-anchor="middle" fill="#333">%d</text>\n}, $xx, $T + $ph + 15, $c;
        printf {$fh} qq{<text x="%.1f" y="%.1f" text-anchor="middle" fill="#999" font-size="9">%.0f keV</text>\n}, $xx, $T + $ph + 28, channel_energy($c, $cal);
    }
    printf {$fh} qq{<text x="%.1f" y="%.1f" text-anchor="middle" fill="#333">channel (keV from the calibration, grey)</text>\n}, $L + $pw / 2, $H - 8;

    # histogram: one vertical line per channel from the baseline to its value
    my $d = '';
    for my $c (0 .. $cmax) {
        next unless $v[$c] > 0;
        my $xx = $x->($c + 0.5);
        $d .= sprintf('M%.1f %.1fV%.1f', $xx, $T + $ph, $y->($v[$c]));
    }
    print {$fh} qq{<path d="$d" fill="none" stroke="#1f5fa8" stroke-width="1"/>\n} if length $d;

    my @colors = ('#d1495b', '#2a9d8f', '#e9a03b', '#6a4c93', '#3c8d2f');
    my $row = 0;
    for my $m (@$marks) {
        my $c = channel_for_energy($m->{energy}, $cal);
        next unless defined $c && $c >= 0 && $c <= $cmax;
        my $col = $colors[ $m->{series} % @colors ];
        my $lx = $x->($c + 0.5);
        printf {$fh} qq{<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" stroke-dasharray="5,3"/>\n}, $lx, $T, $lx, $T + $ph, $col;
        printf {$fh} qq{<text x="%.1f" y="%.1f" fill="%s">%s %.1f keV</text>\n}, $lx + 3, $T + 12 + 12 * ($row++ % 6), $col, _esc($m->{label}), $m->{energy};
    }
    print {$fh} "</svg>\n";
    close $fh or die "cannot write $file: $!\n";
}

sub max_of { my ($a, $b) = @_; return $a > $b ? $a : $b }
sub ceil_int  { my $v = shift; my $i = int($v); return $i < $v ? $i + 1 : $i }
sub floor_int { my $v = shift; my $i = int($v); return $i > $v ? $i - 1 : $i }

# Text (terminal) version of the spectrum plot: the same log histogram by channel, drawn with
# eighth-height block characters. Each column takes the largest channel in its span, so
# narrow peaks stay visible. Matched lines are marked under the axis.
sub render_text {
    my ($reg, $net, $emax, $marks, $width, $height) = @_;
    my $cal = $reg->{calib};
    my $cmax = channel_for_energy($emax, $cal);
    $cmax = NCH - 1 if !defined $cmax || $cmax > NCH - 1;
    $cmax = int($cmax);

    my @v = map { my $x = $net->[$_] / $reg->{seconds}; $x > 0 ? $x : 0 } 0 .. $cmax;
    my $vmax = 0;
    $vmax = $_ > $vmax ? $_ : $vmax for @v;
    $vmax = 1 unless $vmax > 0;
    my $lmax = log($vmax) / log(10);
    my $lmin = $lmax - 4;

    my $label_w = 8;
    my $pw = $width - $label_w;
    $pw = 20 if $pw < 20;
    my $levels = $height * 8;
    my @blocks = (' ', "\x{2581}", "\x{2582}", "\x{2583}", "\x{2584}", "\x{2585}", "\x{2586}", "\x{2587}", "\x{2588}");

    my @col_level;
    for my $x (0 .. $pw - 1) {
        my $c0 = int($x * ($cmax + 1) / $pw);
        my $c1 = int(($x + 1) * ($cmax + 1) / $pw) - 1;
        $c1 = $c0 if $c1 < $c0;
        my $m = 0;
        for my $c ($c0 .. $c1) { $m = $v[$c] if $v[$c] > $m }
        my $lvl = 0;
        if ($m > 0) {
            my $f = (log($m) / log(10) - $lmin) / ($lmax - $lmin);
            $f = 0 if $f < 0;
            $f = 1 if $f > 1;
            $lvl = int($f * $levels + 0.5);
        }
        push @col_level, $lvl;
    }

    binmode(STDOUT, ':encoding(UTF-8)');
    my $decade_row = sub { my $k = shift; return int(($lmax - $k) / ($lmax - $lmin) * $height + 0.5) };
    print "\nSpectrum (net counts/s, log scale; channel across, keV from calibration below):\n";
    for my $r (0 .. $height - 1) {
        my $label = ' ' x $label_w;
        for (my $k = int($lmin) + 1; $k <= int($lmax); $k++) {
            if ($decade_row->($k) == $r) {
                $label = sprintf('%7g ', 10 ** $k);
            }
        }
        my $line = $label . '';
        my $base = ($height - 1 - $r) * 8;
        for my $x (0 .. $pw - 1) {
            my $cell = $col_level[$x] - $base;
            $cell = 0 if $cell < 0;
            $cell = 8 if $cell > 8;
            $line .= $blocks[$cell];
        }
        print "$line\n";
    }
    print ' ' x $label_w, '+', '-' x ($pw - 1), "\n";

    # matched-line marks under the axis
    my @mark_line = (' ') x $pw;
    my @legend;
    my $i = 0;
    for my $m (@$marks) {
        my $c = channel_for_energy($m->{energy}, $cal);
        next unless defined $c && $c >= 0 && $c <= $cmax;
        my $x = int($c * $pw / ($cmax + 1));
        $x = $pw - 1 if $x >= $pw;
        $mark_line[$x] = '^';
        push @legend, sprintf('%s %.1f keV', $m->{label}, $m->{energy});
    }
    print ' ' x $label_w, join('', @mark_line), "\n" if @legend;

    # channel ticks
    my $tick_line = ' ' x $label_w;
    my $step = $cmax <= 300 ? 25 : $cmax <= 700 ? 50 : 100;
    my @t = (' ') x $pw;
    for (my $c = 0; $c <= $cmax; $c += $step) {
        my $x = int($c * $pw / ($cmax + 1));
        my $s = sprintf('%d', $c);
        for my $j (0 .. length($s) - 1) { $t[$x + $j] = substr($s, $j, 1) if $x + $j < $pw }
    }
    print $tick_line, join('', @t), "  (channel)\n";
    print "  marks: ", join(' | ', @legend), "\n" if @legend;
    return;
}

sub usage {
    my ($code) = @_;
    my $text = <<'EOF';
Usage: rcspg-analyze.pl FILE [options]

FILE is a RadiaCode app export (.zrcspg), an extracted .rcspg, or the
spectrogram-DATE.csv written by radiacode.pl --monitor.

Time windows (UTC unless --tz is given; format YYYY-MM-DD HH:MM[:SS]):
  --from T, --to T         spectrum region (default: all records)
  --ref-from T, --ref-to T reference window subtracted from the region
                           (e.g. a quiet period before a burst)
  --tz +HHMM               zone the times above are written in (e.g. +0100)

Output:
  --bin MIN                rate table bin size in minutes (default 5; 0 = none)
  --csv FILE               write the region spectrum, channel by channel
  --svg FILE               write the spectrum plot with matched lines marked
  --tui                  also draw the spectrum as a text chart in the terminal
  --width N, --height N    size of the text chart (default: $COLUMNS or 100, and 16 rows)
  --emax KEV               top of the plot and of the peak list (default 300)

Peaks and matching:
  --sigma S                minimum peak significance (default 4)
  --tol KEV                matching tolerance, absolute part (default 2)
  --min-intensity PCT      library lines weaker than this are ignored (default 3)
  --nuclides LIST          comma list of labels to match (default: built-in set,
                           e.g. Am-241,Tc-99m,Tl-201,I-131,Co-57,Cs-137)
  --lines MODE             auto (default: online, else built-in), online, builtin
  --cache-dir DIR          where IAEA lookups are cached
                           (default ~/.cache/radiacode-perl)
  --calib A0,A1,A2         override the energy calibration (keV = a0 + a1 ch + a2 ch^2)
  --max-shift KEV          largest energy shift tried when matching lines (default 3).
                           The gain is not fitted: use --calib to test a scale instead

  -h, --help               this text
EOF
    print $text;
    exit $code;
}

# ============================================================================
# Main
# ============================================================================

sub run {
    my @args = @_;
    my %o = (
        bin => 5, emax => 300, sigma => 4, tol => 2, 'min-intensity' => 3,
        lines => 'auto', 'cache-dir' => default_cache_dir(), tz => '+0000', 'max-shift' => 3, width => ($ENV{COLUMNS} || 100), height => 16,
    );
    GetOptionsFromArray(\@args, \%o,
        'from=s', 'to=s', 'ref-from=s', 'ref-to=s', 'tz=s', 'bin=f', 'emax=f', 'sigma=f',
        'tol=f', 'min-intensity=f', 'nuclides=s', 'lines=s', 'cache-dir=s', 'csv=s', 'svg=s',
        'calib=s', 'max-shift=f', 'tui', 'width=i', 'height=i', 'help|h') or usage(2);
    usage(0) if $o{help};
    my $file = shift @args or usage(2);
    die "--lines must be auto, online or builtin\n" unless $o{lines} =~ /^(auto|online|builtin)$/;

    my $recs = read_input($file);
    if (defined $o{calib}) {
        my @cal = split /,/, $o{calib};
        die "--calib wants A0,A1,A2\n" unless @cal == 3;
        $_->{calib} = [@cal] for @$recs;
    }

    my $from = defined $o{from} ? parse_local_time($o{from}, $o{tz}) : undef;
    my $to   = defined $o{to}   ? parse_local_time($o{to}, $o{tz})   : undef;
    my $reg_recs = select_records($recs, $from, $to);
    my $reg = make_spectrum($reg_recs);

    my $ref;
    if (defined $o{'ref-from'} || defined $o{'ref-to'}) {
        my $rf = defined $o{'ref-from'} ? parse_local_time($o{'ref-from'}, $o{tz}) : undef;
        my $rt = defined $o{'ref-to'}   ? parse_local_time($o{'ref-to'}, $o{tz})   : undef;
        $ref = make_spectrum(select_records($recs, $rf, $rt));
    }

    my $cal = $reg->{calib};
    printf "Input:       %s\n", $file;
    printf "Records:     %d (%s to %s UTC)\n", scalar @$recs, fmt_utc($recs->[0]{t}), fmt_utc($recs->[-1]{t});
    printf "Calibration: keV = %.6g + %.6g*ch + %.6g*ch^2\n", @$cal;
    printf "Region:      %d records, %.0f s, %d counts, %.3f cps (UTC %s to %s)\n",
        $reg->{records}, $reg->{seconds}, sum0(@{ $reg->{counts} }),
        sum0(@{ $reg->{counts} }) / $reg->{seconds},
        fmt_utc($reg_recs->[0]{t}), fmt_utc($reg_recs->[-1]{t});
    if ($ref) {
        printf "Reference:   %d records, %.0f s, %.3f cps (subtracted, scaled to the region time)\n",
            $ref->{records}, $ref->{seconds}, sum0(@{ $ref->{counts} }) / $ref->{seconds};
    }

    if ($o{bin} > 0) {
        print "\nCount rate by $o{bin}-minute bin within the region (UTC):\n";
        printf "  %-19s %8s %10s %9s %9s %9s\n", 'start', 'records', 'counts', 'seconds', 'cps', 'cpm';
        for my $b (@{ rate_bins($reg_recs, $o{bin}) }) {
            my $cps = $b->{seconds} ? $b->{counts} / $b->{seconds} : 0;
            printf "  %-19s %8d %10d %9.0f %9.2f %9.0f\n",
                fmt_utc($b->{t}), $b->{records}, $b->{counts}, $b->{seconds}, $cps, $cps * 60;
        }
    }

    my ($net, $var) = net_spectrum($reg, $ref);
    my $peaks = [ grep { $_->{energy} <= $o{emax} }
                  @{ find_peaks($net, $var, $cal, $reg->{seconds}, $o{sigma}) } ];
    print "\nPeaks (sigma >= $o{sigma}, approximate; energies on the device scale):\n";
    if (@$peaks) {
        printf "  %9s %10s %8s\n", 'keV', 'net cps', 'sigma';
        printf "  %9.1f %10.3f %8.1f\n", @{$_}{qw(energy cps sigma)} for @$peaks;
    } else {
        print "  none\n";
    }

    my ($lines, $notes) = load_lines(
        mode => $o{lines}, nuclides => _nuclide_list($o{nuclides}),
        cache_dir => $o{'cache-dir'}, min_I => $o{'min-intensity'},
    );
    print "\n$_\n" for map { "Note: $_" } @$notes;
    my @all_lines = map { @$_ } values %$lines;
    if (!@all_lines) {
        print "\nNo gamma lines available to match.\n";
    } elsif (@$peaks) {
        my ($g, $off, $score) = best_calibration(\@all_lines, $peaks, $o{tol}, 0.02, $o{'max-shift'});
        my $cpeaks = corrected_peaks($peaks, $g, $off);
        printf "\nDevice energies shifted to library energies: %+.2f keV (score %.2f)\n", $off, $score;
        if (@$peaks < 3) {
            print "  Only ", scalar @$peaks, " significant peak(s): matches below are weak evidence.\n";
        }
        print "\nIsotope candidates (share of library gamma intensity found at a peak):\n";
        printf "  %-8s %10s %14s %s\n", 'nuclide', 'lines', 'intensity', 'strongest line seen?';
        my @ranked = score_nuclides($lines, $cpeaks, $o{tol}, 0.02);
        for my $r (@ranked) {
            next unless $r->{frac} > 0;
            printf "  %-8s %4d/%-5d %12.1f%% %s (%.1f keV, %.1f%%)\n",
                $r->{nuc}, $r->{matched}, $r->{lines}, 100 * $r->{frac},
                $r->{strongest_seen} ? 'yes' : 'no',
                $r->{strongest}{E}, $r->{strongest}{I};
        }
        print "  (none)\n" unless grep { $_->{frac} > 0 } @ranked;

        my @marks;
        my $series = 0;
        for my $r (grep { $_->{frac} > 0 } @ranked[0 .. ($#ranked < 2 ? $#ranked : 2)]) {
            for my $L (@{ $lines->{ $r->{nuc} } }) {
                my $dev = ($L->{E} - $off) / $g;   # back onto the device scale for the plot
                next unless $dev >= 0 && $dev <= $o{emax};
                push @marks, { energy => $dev, label => $r->{nuc}, series => $series };
            }
            $series++;
        }
        render_text($reg, $net, $o{emax}, \@marks, $o{width}, $o{height}) if $o{tui};
        if ($o{svg}) {
            write_svg($o{svg}, $reg, $net, $o{emax}, \@marks);
            print "\nSpectrum plot written to $o{svg}\n";
        }
    }

    if ($o{csv}) {
        write_csv($o{csv}, $reg, $net);
        print "Spectrum table written to $o{csv}\n";
    }
    print "\nThe match is a guide only: the device calibration and this resolution are rough,\n";
    print "so check the strongest line of any candidate before trusting it.\n";
    return 0;
}

sub _nuclide_list {
    my ($want) = @_;
    return \@NUCLIDES unless defined $want && length $want;
    my %w = map { $_ => 1 } split /,/, $want;
    return [ grep { $w{ $_->[1] } } @NUCLIDES ];
}

package main;

sub main { exit RadiaCode::Analyze::run(@ARGV) }
main() unless caller;

1;
