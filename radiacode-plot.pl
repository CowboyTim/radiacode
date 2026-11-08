#!/usr/bin/perl
#
# radiacode-plot.pl - draw SVG graphs from the CSV logs written by radiacode.pl --monitor
#
#   ./radiacode-plot.pl [DIR]            # reads DIR/rates.csv, events.csv, spectrum.csv
#
# Writes into DIR:
#   rates.svg     count rate (cpm) and dose rate (uSv/h) over time, alarm events marked
#   spectrum.svg  change of the energy spectrum over time (heatmap, log colour scale)
#
# Only core Perl modules are used.

use strict;
use warnings;
use Time::Local qw(timegm);

my $dir = shift // './radiacode-data';
die "no such directory: $dir\n" unless -d $dir;

# Parse "YYYY-MM-DDTHH:MM:SS.mmm+HHMM" into epoch seconds (fractional part kept).
sub parse_iso {
    my ($s) = @_;
    return unless $s =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?([+-])(\d\d)(\d\d)$/;
    my ($y, $mo, $d, $h, $mi, $se, $frac, $sign, $oh, $om) = ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10);
    my $offset = ($oh * 3600 + $om * 60) * ($sign eq '-' ? -1 : 1);
    return timegm($se, $mi, $h, $d, $mo - 1, $y) - $offset + ($frac ? "0.$frac" : 0);
}

sub read_csv {
    my ($file) = @_;
    return [] unless -f $file;
    open(my $fh, '<', $file) or die "cannot read $file: $!\n";
    my $hdr = <$fh>;
    chomp $hdr;
    my @cols = split /,/, $hdr;
    my @rows;
    while (my $line = <$fh>) {
        chomp $line;
        my @f = split /,/, $line, -1;
        my %r;
        @r{@cols} = @f;
        push @rows, \%r;
    }
    close $fh;
    return \@rows;
}

sub esc {
    my ($t) = @_;
    $t =~ s/&/&amp;/g; $t =~ s/</&lt;/g; $t =~ s/>/&gt;/g;
    return $t;
}

sub fmt_time {
    my ($t) = @_;
    my @l = localtime($t);
    return sprintf('%02d:%02d', $l[2], $l[1]);
}

# ---------------------------------------------------------------- rates.svg
sub plot_rates {
    my ($rates, $events, $out) = @_;
    my @pts = grep { defined $_->[0] } map { [parse_iso($_->{time}), $_] } @$rates;
    unless (@pts) {
        warn "no rate data, skipping rates.svg\n";
        return;
    }
    my ($t0, $t1) = ($pts[0][0], $pts[-1][0]);
    $t1 = $t0 + 1 if $t1 <= $t0;

    my ($W, $H) = (1000, 640);
    my ($L, $R, $PT, $PH, $GAP, $B) = (80, 30, 50, 220, 60, 50);
    my $pw = $W - $L - $R;
    my $ymaxc = 0; my $ymaxd = 0;
    for (@pts) {
        $ymaxc = $_->[1]{cpm} if $_->[1]{cpm} > $ymaxc;
        $ymaxd = $_->[1]{dose_rate_uSv_h} if $_->[1]{dose_rate_uSv_h} > $ymaxd;
    }
    $ymaxc = 1 if $ymaxc <= 0;   $ymaxd = 0.001 if $ymaxd <= 0;
    my $X = sub { $L + ($_[0] - $t0) / ($t1 - $t0) * $pw };
    my ($yc0, $yd0) = ($PT, $PT + $PH + $GAP);
    my $Y = sub { my ($v, $top, $ymax) = @_; $top + $PH - $v / $ymax * $PH };
    my $H2 = $yd0 + $PH + $B;

    my @s = (qq(<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H2" font-family="sans-serif" font-size="12">),
             qq(<rect width="$W" height="$H2" fill="#fff"/>),
             qq(<text x="$L" y="26" font-size="16" font-weight="bold">Count rate and dose rate</text>));

    # panel frames, y ticks
    for my $p ([$yc0, $ymaxc, 'counts per minute'], [$yd0, $ymaxd, 'dose rate, uSv/h']) {
        my ($top, $ymax, $label) = @$p;
        push @s, qq(<rect x="$L" y="$top" width="$pw" height="$PH" fill="none" stroke="#333"/>);
        for my $f (0, 0.25, 0.5, 0.75, 1) {
            my $y = $top + $PH - $f * $PH;
            push @s, qq(<line x1="$L" y1="$y" x2="@{[$L+$pw]}" y2="$y" stroke="#eee"/>),
                     sprintf(qq(<text x="%d" y="%.1f" text-anchor="end">%s</text>), $L - 6, $y + 4,
                             $ymax * $f >= 10 ? sprintf('%.0f', $ymax * $f) : sprintf('%.3g', $ymax * $f));
        }
        push @s, qq(<text transform="translate(20,@{[$top+$PH/2]}) rotate(-90)" text-anchor="middle">$label</text>);
    }

    # series
    my $path_c = join ' ', map { sprintf('%.1f,%.1f', $X->($_->[0]), $Y->($_->[1]{cpm}, $yc0, $ymaxc)) } @pts;
    my $path_d = join ' ', map { sprintf('%.1f,%.1f', $X->($_->[0]), $Y->($_->[1]{dose_rate_uSv_h}, $yd0, $ymaxd)) } @pts;
    push @s, qq(<polyline fill="none" stroke="#1f6feb" stroke-width="1.2" points="$path_c"/>),
             qq(<polyline fill="none" stroke="#d1642a" stroke-width="1.2" points="$path_d"/>);

    # alarm / device events as markers
    for my $e (@$events) {
        my $t = parse_iso($e->{time}) // next;
        next if $t < $t0 || $t > $t1;
        my $x = $X->($t);
        my $alarm = $e->{event_name} =~ /ALARM|OFFSCALE/;
        push @s, sprintf(qq(<line x1="%.1f" y1="%d" x2="%.1f" y2="%d" stroke="%s" stroke-dasharray="4 3"/>),
                         $x, $yc0, $x, $yd0 + $PH, $alarm ? '#c00' : '#888'),
                 sprintf(qq(<text x="%.1f" y="%d" font-size="10" fill="%s">%s</text>), $x + 3, $yc0 + 12,
                         $alarm ? '#c00' : '#555', esc($e->{event_name}));
    }

    # x ticks (every ~1/8 of the range)
    for my $i (0 .. 8) {
        my $t = $t0 + ($t1 - $t0) * $i / 8;
        my $x = $X->($t);
        push @s, sprintf(qq(<text x="%.1f" y="%d" text-anchor="middle">%s</text>), $x, $H2 - 20, fmt_time($t));
    }
    push @s, qq(<text x="@{[$L+$pw/2]}" y="@{[$H2-4]}" text-anchor="middle">local time</text>);
    push @s, qq(<text x="$L" y="44" fill="#1f6feb">blue: counts per minute</text>),
             qq(<text x="@{[$L+200]}" y="44" fill="#d1642a">orange: dose rate (uSv/h)</text>),
             qq(<text x="@{[$L+420]}" y="44" fill="#c00">red dashed: alarm event</text>);
    push @s, '</svg>';

    open(my $fh, '>', $out) or die "cannot write $out: $!\n";
    print {$fh} join("\n", @s), "\n";
    close $fh;
    print "wrote $out (", scalar(@pts), " rate points, ", scalar(@$events), " events)\n";
}

# ---------------------------------------------------------- spectrum.svg
sub plot_spectrum {
    my ($spec, $out) = @_;
    unless (@$spec) {
        warn "no spectrum data, skipping spectrum.svg\n";
        return;
    }
    # Group rows by timestamp, then merge into at most $MAXT time rows.
    my (%by_time, @times);
    my $emax = 0;
    for my $r (@$spec) {
        my $t = parse_iso($r->{time}) // next;
        push @times, $t unless exists $by_time{$t};
        $by_time{$t}{$r->{channel}} = [$r->{energy_keV}, $r->{counts}];
        $emax = $r->{energy_keV} if $r->{energy_keV} > $emax;
    }
    my @tk = sort { $a <=> $b } keys %by_time;
    my $MAXT = 300;
    my $per = int(@tk / $MAXT) + 1;     # time rows per bucket
    my $NB  = 128;                        # energy bins
    my @grid;                             # [bucket][bin] = counts
    for my $i (0 .. $#tk) {
        my $b = int($i / $per);
        for my $ch (keys %{ $by_time{$tk[$i]} }) {
            my ($kev, $c) = @{ $by_time{$tk[$i]}{$ch} };
            my $bin = int($kev / $emax * ($NB - 1) + 0.5);
            $bin = $NB - 1 if $bin >= $NB;
            $grid[$b][$bin] += $c;
        }
    }
    my $nb_t = scalar @grid;
    my ($W, $H) = (1000, 520);
    my ($L, $R, $T, $B) = (80, 30, 50, 60);
    my $pw = $W - $L - $R; my $ph = $H - $T - $B;
    my $cw = $pw / $NB; my $ch = $ph / $nb_t;
    my $vmax = 0;
    for my $row (@grid) { for my $v (grep { defined } @$row) { $vmax = $v if $v > $vmax } }
    my $lmax = log($vmax + 1) / log(10);

    my @s = (qq(<svg xmlns="http://www.w3.org/2000/svg" width="$W" height="$H" font-family="sans-serif" font-size="12">),
             qq(<rect width="$W" height="$H" fill="#fff"/>),
             qq(<text x="$L" y="26" font-size="16" font-weight="bold">Spectrum change over time (counts per interval, log colour)</text>));
    for my $b (0 .. $nb_t - 1) {
        for my $bin (0 .. $NB - 1) {
            my $v = $grid[$b][$bin] // 0;
            next unless $v > 0;
            my $f = log($v + 1) / log(10) / $lmax;   # 0..1
            my $r = int(255 * (1 - $f)); my $g = int(255 * (1 - $f) + 80 * $f); my $bl = 255;
            push @s, sprintf(qq(<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="rgb(%d,%d,%d)"/>),
                $L + $bin * $cw, $T + $b * $ch, $cw + 0.3, $ch + 0.3, $r, $g, $bl);
        }
    }
    push @s, qq(<rect x="$L" y="$T" width="$pw" height="$ph" fill="none" stroke="#333"/>);
    for my $i (0 .. 7) {
        my $kev = $emax * $i / 7;
        my $x = $L + $pw * $i / 7;
        push @s, sprintf(qq(<text x="%.1f" y="%d" text-anchor="middle">%d keV</text>), $x, $H - 30, $kev);
    }
    my $t0 = $times[0] // $tk[0];
    push @s, sprintf(qq(<text x="%d" y="%d" text-anchor="end">%s</text>), $L - 6, $T + 12, fmt_time($tk[0]));
    push @s, sprintf(qq(<text x="%d" y="%d" text-anchor="end">%s</text>), $L - 6, $T + $ph, fmt_time($tk[-1]));
    push @s, qq(<text x="@{[$L+$pw/2]}" y="@{[$H-8]}" text-anchor="middle">energy (keV), top = earliest, bottom = latest</text>);
    push @s, '</svg>';

    open(my $fh, '>', $out) or die "cannot write $out: $!\n";
    print {$fh} join("\n", @s), "\n";
    close $fh;
    print "wrote $out ($nb_t time rows, $NB energy bins, max $vmax counts)\n";
}

my $rates  = read_csv("$dir/rates.csv");
my $events = read_csv("$dir/events.csv");
my $spec   = read_csv("$dir/spectrum.csv");
plot_rates($rates, $events, "$dir/rates.svg");
plot_spectrum($spec, "$dir/spectrum.svg");
