#!/usr/bin/perl
#
# radiacode.pl - BLE client for the RadiaCode 10x radiation detector (RC-110 etc.)
#
# Protocol reference (reverse engineered, see cdump/radiacode on GitHub):
#   https://github.com/cdump/radiacode  (src/radiacode/transports/bluetooth.py, radiacode.py)
#
# GATT profile:
#   Write char:  e63215e6-7003-49d8-96b0-b024798fb901  (ATT Write Command, 18-byte chunks)
#   Notify char: e63215e7-7003-49d8-96b0-b024798fb901  (subscribe CCCD, responses arrive as notifications)
#
# Request framing (little-endian):
#   [LEN u32][cmd u16][0x00][seq u8][args...]     LEN = length of everything after LEN
#   seq = 0x80 + (n % 32); the response starts with the same 4-byte header (cmd, 0, seq).
#   Responses arrive as notifications: the first 4 bytes of the reassembled stream are
#   a u32 LEN (of the response, including its 4-byte header), followed by the response.
#
# Usage:
#   ./radiacode.pl -d AA:BB:CC:DD:EE:FF --info
#   ./radiacode.pl -d AA:BB:CC:DD:EE:FF --config
#   ./radiacode.pl -d AA:BB:CC:DD:EE:FF                    # live realtime readings (Ctrl-C to stop)
#   ./radiacode.pl -d AA:BB:CC:DD:EE:FF --interval 5 --count 10
#   ./radiacode.pl -d AA:BB:CC:DD:EE:FF --buffer           # dump all buffered records once
#
# NOTE: The RadiaCode must not be connected to another host (e.g. the phone app) at the same time.

use strict;
use warnings;
use bytes;
use Getopt::Long;
use POSIX qw(strftime);

my %opts = (
    device            => undef,
    addr_type         => 'public',
    connect_timeout   => 5,
    debug             => 0,
    write_uuid        => 'e63215e6-7003-49d8-96b0-b024798fb901',
    notify_uuid       => 'e63215e7-7003-49d8-96b0-b024798fb901',
    interval          => 2,
    count             => 0,
);

my ($do_info, $do_config, $do_buffer) = (0, 0, 0);

GetOptions(
    'device|d=s'        => \$opts{device},
    'addr-type=s'       => \$opts{addr_type},
    'connect-timeout=f' => \$opts{connect_timeout},
    'write-uuid=s'      => \$opts{write_uuid},
    'notify-uuid=s'     => \$opts{notify_uuid},
    'interval|i=f'      => \$opts{interval},
    'count|n=i'         => \$opts{count},
    'info'              => \$do_info,
    'config'            => \$do_config,
    'buffer'            => \$do_buffer,
    'debug|v+'          => \$opts{debug},
    'help|h'            => sub { print_usage(); exit 0; },
) or do { print_usage(); exit 1; };

unless ($opts{device}) {
    print STDERR "Error: -d / --device is required\n";
    print_usage();
    exit 1;
}
unless ($opts{device} =~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
    print STDERR "Error: Invalid Bluetooth address format\n";
    exit 1;
}
if ($opts{addr_type} !~ /^(?:public|random)$/i) {
    print STDERR "Error: --addr-type must be 'public' or 'random'\n";
    exit 1;
}
if ($opts{interval} <= 0) {
    print STDERR "Error: --interval must be > 0\n";
    exit 1;
}

my $rc_dev = RadiaCode::BLE->new(%opts);
exit $rc_dev->run(
    info   => $do_info,
    config => $do_config,
    buffer => $do_buffer,
    count  => $opts{count},
    interval => $opts{interval},
);

# ============================================================================
# RadiaCode::BLE class
# ============================================================================

package RadiaCode::BLE;

use Errno   qw(EAGAIN EINPROGRESS);
use Fcntl   qw(O_NONBLOCK F_SETFL F_GETFL);
use Socket  qw(SOCK_SEQPACKET SOL_SOCKET SO_ERROR);
use POSIX   qw(strftime);

use constant {
    AF_BLUETOOTH              => 31,
    BTPROTO_L2CAP             => 0,
    BDADDR_LE_PUBLIC          => 0x01,
    BDADDR_LE_RANDOM          => 0x02,

    ATT_ERROR_RSP             => 0x01,
    ATT_FIND_INFO_REQ         => 0x04,
    ATT_FIND_INFO_RSP         => 0x05,
    ATT_READ_BY_TYPE_REQ      => 0x08,
    ATT_READ_BY_TYPE_RSP      => 0x09,
    ATT_WRITE_REQ             => 0x12,
    ATT_WRITE_RSP             => 0x13,
    ATT_WRITE_CMD             => 0x52,
    ATT_HANDLE_VALUE_NOTIF    => 0x1B,

    GATT_CHARACTERISTIC_UUID  => 0x2803,
    GATT_CCCD_UUID            => 0x2902,

    # RadiaCode command IDs (request header u16)
    CMD_GET_VERSION           => 0x000A,
    CMD_GET_SERIAL            => 0x000B,
    CMD_SET_EXCHANGE          => 0x0007,
    CMD_SET_TIME              => 0x0A04,
    CMD_WR_VIRT_SFR           => 0x0825,
    CMD_RD_VIRT_STRING        => 0x0826,

    # Virtual strings
    VS_CONFIGURATION          => 0x0002,
    VS_SERIAL_NUMBER          => 0x0008,
    VS_DATA_BUF               => 0x0100,

    # Virtual SFRs
    VSFR_DEVICE_TIME          => 0x0504,

    ATT_CHUNK                 => 18,   # max payload per Write Command, as used by cdump/radiacode
    RESPONSE_TIMEOUT          => 10.0,
};

sub new {
    my ($class, %o) = @_;
    bless {
        device          => $o{device},
        addr_type       => lc($o{addr_type} // 'public'),
        connect_timeout => $o{connect_timeout} // 5,
        debug           => $o{debug} // 0,
        write_uuid      => lc($o{write_uuid}  // 'e63215e6-7003-49d8-96b0-b024798fb901'),
        notify_uuid     => lc($o{notify_uuid} // 'e63215e7-7003-49d8-96b0-b024798fb901'),

        socket          => undef,
        h_write         => 0,     # value handle of write characteristic
        h_notify        => 0,     # value handle of notify characteristic
        h_cccd          => 0,     # CCCD handle of notify characteristic
        seq             => 0,
        base_time       => 0,     # epoch seconds corresponding to device ts_offset 0
    }, $class;
}

# ============================================================================
# Top-level workflow
# ============================================================================

sub run {
    my ($self, %todo) = @_;

    print STDERR "Device: $self->{device}\n";

    unless ($self->ble_connect()) {
        print STDERR "ERROR: BLE connection failed\n";
        return 1;
    }

    my $rc = 1;
    eval {
        unless ($self->discover_handles()) {
            print STDERR "ERROR: RadiaCode write/notify characteristics not found\n";
            die "discover\n";
        }
        unless ($self->subscribe_notify()) {
            print STDERR "ERROR: Could not enable notifications (CCCD)\n";
            die "cccd\n";
        }
        unless ($self->init_device()) {
            print STDERR "ERROR: Device initialisation failed (is another host connected?)\n";
            die "init\n";
        }

        $rc = 0;
        if ($todo{info}) {
            $rc |= $self->print_info();
        }
        if ($todo{config}) {
            $rc |= $self->print_config();
        }
        if ($todo{buffer}) {
            $rc |= $self->print_buffer();
        }
        if (!$todo{info} && !$todo{config} && !$todo{buffer}) {
            $rc |= $self->live($todo{interval}, $todo{count});
        }
        1;
    } or do {
        print STDERR "ERROR: $@" if $@ && $@ ne "discover\n" && $@ ne "cccd\n" && $@ ne "init\n";
        $rc = 1;
    };

    $self->ble_disconnect();
    return $rc;
}

# ============================================================================
# BLE connection (raw L2CAP ATT channel, CID 4)
# ============================================================================

sub ble_connect {
    my ($self) = @_;
    my @oct    = split(':', $self->{device});
    my $bdaddr = pack('C6', map { hex($_) } reverse @oct);
    my $atype  = ($self->{addr_type} eq 'random') ? BDADDR_LE_RANDOM : BDADDR_LE_PUBLIC;

    socket(my $sock, AF_BLUETOOTH, SOCK_SEQPACKET, BTPROTO_L2CAP) or return 0;

    # Bind local LE-public any-address, ATT fixed channel (CID 4)
    bind($sock, pack('S S a6 S S', AF_BLUETOOTH, 0, "\0" x 6, 4, BDADDR_LE_PUBLIC))
        or do { close($sock); return 0; };

    my $peer = pack('S S a6 S S', AF_BLUETOOTH, 0, $bdaddr, 4, $atype);
    fcntl($sock, F_SETFL, fcntl($sock, F_GETFL, 0) | O_NONBLOCK);

    my $connected = connect($sock, $peer);
    if (!$connected && !($! == EINPROGRESS || $! == EAGAIN)) {
        $self->debug("connect() immediate fail: $!");
        close($sock); return 0;
    }

    unless ($connected) {
        my $deadline = time() + ($self->{connect_timeout} > 0 ? $self->{connect_timeout} : 5);
        my $done     = 0;
        while (time() < $deadline) {
            my $fh   = fileno($sock);
            my $wvec = '';
            vec($wvec, $fh, 1) = 1;
            my $n = select(undef, $wvec, my $evec = $wvec, 0.5);
            next unless defined($n) && $n > 0;
            my $err = getsockopt($sock, SOL_SOCKET, SO_ERROR);
            my $eno = $err ? unpack('I', $err) : 0;
            if (!$eno)                                { $done = 1; last; }
            next if $eno == EINPROGRESS || $eno == EAGAIN;
            last;
        }
        unless ($done) { $self->debug('connect timeout'); close($sock); return 0; }
    }

    my $err = getsockopt($sock, SOL_SOCKET, SO_ERROR);
    if ($err && unpack('I', $err)) { close($sock); return 0; }

    fcntl($sock, F_SETFL, fcntl($sock, F_GETFL, 0) & ~O_NONBLOCK);
    $self->{socket} = $sock;
    return 1;
}

sub ble_disconnect {
    my ($self) = @_;
    if ($self->{socket}) {
        close($self->{socket});
        $self->{socket} = undef;
    }
}

# Convert "e63215e6-7003-..." into the little-endian 16-byte form used in ATT.
sub uuid_le_bytes {
    my ($u) = @_;
    (my $hex = lc $u) =~ s/-//g;
    return join('', reverse split //, pack('H*', $hex));
}

# Walk all characteristic declarations and locate the write and notify characteristics
# by their 128-bit UUIDs. Sets h_write (value handle) and h_notify (value handle).
sub discover_handles {
    my ($self) = @_;

    my $want_w = uuid_le_bytes($self->{write_uuid});
    my $want_n = uuid_le_bytes($self->{notify_uuid});
    my ($start, $last_decl_start) = (0x0001, 0);

    while ($start <= 0xFFFE) {
        my $rsp = $self->att_request(
            pack('C v v v', ATT_READ_BY_TYPE_REQ, $start, 0xFFFF, GATT_CHARACTERISTIC_UUID),
            2.0
        );
        last unless defined $rsp && length($rsp) >= 2;
        last if ord(substr($rsp, 0, 1)) != ATT_READ_BY_TYPE_RSP;   # error => end of list

        my $elen = ord(substr($rsp, 1, 1));
        last if $elen < 7;

        my $pos = 2;
        my $next = $start;
        while ($pos + $elen <= length($rsp)) {
            my $e    = substr($rsp, $pos, $elen);
            my $decl = unpack('v', substr($e, 0, 2));
            my $val  = unpack('v', substr($e, 3, 2));
            my $uuid = substr($e, 5);            # 2 or 16 bytes, little endian

            $self->debug(sprintf('  characteristic decl=0x%04X value=0x%04X uuid=%s',
                $decl, $val, unpack('H*', $uuid)));

            if ($uuid eq $want_w) { $self->{h_write}  = $val; }
            if ($uuid eq $want_n) { $self->{h_notify} = $val; }

            $next = $decl + 1;
            $pos += $elen;
        }
        last if $next <= $start;   # no progress, avoid endless loop
        $start = $next;
    }

    unless ($self->{h_write} && $self->{h_notify}) {
        $self->debug(sprintf('write=0x%04X notify=0x%04X', $self->{h_write}, $self->{h_notify}));
        return 0;
    }

    # Find the CCCD descriptor (0x2902) right after the notify value handle.
    $self->{h_cccd} = $self->{h_notify} + 1;
    my $fi = $self->att_request(
        pack('C v v', ATT_FIND_INFO_REQ, $self->{h_notify} + 1, $self->{h_notify} + 2), 2.0);
    if (defined $fi && length($fi) >= 4 && ord(substr($fi, 0, 1)) == ATT_FIND_INFO_RSP
        && ord(substr($fi, 1, 1)) == 1) {
        my $p = 2;
        while ($p + 4 <= length($fi)) {
            my ($h, $t) = unpack('v v', substr($fi, $p, 4));
            $self->{h_cccd} = $h if $t == GATT_CCCD_UUID;
            $p += 4;
        }
    }

    $self->debug(sprintf('write=0x%04X notify=0x%04X cccd=0x%04X',
        $self->{h_write}, $self->{h_notify}, $self->{h_cccd}));
    return 1;
}

# ============================================================================
# ATT helpers
# ============================================================================

# Generic write-then-read for ATT request/response pairs (GATT discovery, CCCD).
sub att_request {
    my ($self, $req, $timeout) = @_;
    $timeout //= 2.0;
    return unless $self->{socket};
    $self->_drain();
    syswrite($self->{socket}, $req) or return;
    return $self->_recv_pdu($timeout);
}

# Read one ATT PDU from the socket with a timeout. Returns bytes or undef.
sub _recv_pdu {
    my ($self, $timeout) = @_;
    return unless $self->{socket};
    my $rin = '';
    vec($rin, fileno($self->{socket}), 1) = 1;
    my $n = select(my $rout = $rin, undef, undef, $timeout);
    return unless defined($n) && $n > 0;
    my $raw = '';
    my $r = sysread($self->{socket}, $raw, 512);
    return unless defined($r) && $r > 0;
    return $raw;
}

# Discard any pending ATT PDUs (stale notifications).
sub _drain {
    my ($self) = @_;
    while (defined(my $p = $self->_recv_pdu(0.0))) { }
}

sub subscribe_notify {
    my ($self) = @_;
    my $rsp = $self->att_request(pack('C v v', ATT_WRITE_REQ, $self->{h_cccd}, 0x0001), 2.0);
    my $ok  = defined($rsp) && length($rsp) >= 1 && ord(substr($rsp, 0, 1)) == ATT_WRITE_RSP;
    $self->debug($ok ? 'Notifications enabled' : 'CCCD write failed');
    return $ok;
}

# ============================================================================
# RadiaCode framed request/response
# ============================================================================

# Send one framed command and return the response body (after the 4-byte header
# echo), or undef on error/timeout.
sub execute {
    my ($self, $cmd, $args) = @_;
    $args //= '';
    return unless $self->{socket} && $self->{h_write};

    my $seq = 0x80 + $self->{seq};
    $self->{seq} = ($self->{seq} + 1) % 32;

    my $hdr = pack('v C C', $cmd, 0, $seq);
    my $req = $hdr . $args;
    my $frame = pack('V', length $req) . $req;

    $self->_drain();
    $self->debug('TX: ' . unpack('H*', $frame));

    for (my $pos = 0; $pos < length $frame; $pos += ATT_CHUNK) {
        my $chunk = substr($frame, $pos, ATT_CHUNK);
        syswrite($self->{socket}, pack('C v', ATT_WRITE_CMD, $self->{h_write}) . $chunk)
            or return;
    }

    my $resp = $self->_read_response() or return;
    my ($rhdr, $body) = (substr($resp, 0, 4), substr($resp, 4));
    unless ($rhdr eq $hdr) {
        $self->debug('header mismatch: req=' . unpack('H*', $hdr) . ' resp=' . unpack('H*', $rhdr));
        return;
    }
    return $body;
}

# Reassemble notification fragments into one response.
# Stream = [u32 LEN][LEN bytes]; LEN covers the response header + body.
sub _read_response {
    my ($self) = @_;
    my $buf   = '';
    my $total;   # total bytes expected in the stream including the 4-byte length prefix
    my $deadline = time() + RESPONSE_TIMEOUT;

    while (1) {
        my $left = $deadline - time();
        return if $left <= 0;
        my $pdu = $self->_recv_pdu($left) or return;

        my $op = ord(substr($pdu, 0, 1));
        unless ($op == ATT_HANDLE_VALUE_NOTIF
                && unpack('v', substr($pdu, 1, 2)) == $self->{h_notify}) {
            $self->debug(sprintf('skipping ATT opcode 0x%02X', $op));
            next;
        }
        my $val = substr($pdu, 3);
        $self->debug('RX: ' . unpack('H*', $val));
        $buf .= $val;

        if (!defined $total && length($buf) >= 4) {
            $total = 4 + unpack('l<', substr($buf, 0, 4));
        }
        if (defined $total && length($buf) >= $total) {
            return substr($buf, 4, $total - 4);
        }
    }
}

sub read_vs {
    my ($self, $id) = @_;
    my $r = $self->execute(CMD_RD_VIRT_STRING, pack('V', $id)) or return;
    return unless length($r) >= 8;
    my ($retcode, $flen) = unpack('V V', substr($r, 0, 8));
    return unless $retcode == 1;
    my $data = substr($r, 8);
    # Firmware quirk (see cdump/radiacode): sometimes a trailing NUL is appended.
    if (length($data) == $flen + 1 && substr($data, -1) eq "\0") {
        chop $data;
    }
    return unless length($data) == $flen;
    return $data;
}

sub write_vsfr {
    my ($self, $id, $data) = @_;
    my $r = $self->execute(CMD_WR_VIRT_SFR, pack('V', $id) . ($data // '')) or return 0;
    return length($r) >= 4 && unpack('V', substr($r, 0, 4)) == 1;
}

# Handshake, time sync and base time (mirrors cdump/radiacode RadiaCode.__init__).
sub init_device {
    my ($self) = @_;

    # execute() returns '' (not undef) for a valid empty body, so test definedness.
    defined $self->execute(CMD_SET_EXCHANGE, "\x01\xff\x12\xff") or return 0;

    my @t = localtime(time());
    my $tm = pack('C8', $t[3], $t[4] + 1, ($t[5] + 1900) - 2000, 0, $t[0], $t[1], $t[2], 0);
    defined $self->execute(CMD_SET_TIME, $tm) or return 0;

    $self->write_vsfr(VSFR_DEVICE_TIME, pack('V', 0)) or return 0;
    $self->{base_time} = time() + 128;

    my $ver = $self->fw_version();
    if (defined $ver) {
        my ($bmaj, $bmin, $tmaj, $tmin) = @{$ver}{qw(boot_major boot_minor target_major target_minor)};
        $self->debug("firmware target $tmaj.$tmin, boot $bmaj.$bmin");
        if ($tmaj < 4 || ($tmaj == 4 && $tmin < 8)) {
            print STDERR "WARNING: firmware $tmaj.$tmin is older than 4.8; protocol may differ\n";
        }
    }
    return 1;
}

sub fw_version {
    my ($self) = @_;
    my $r = $self->execute(CMD_GET_VERSION) or return;
    my ($bminor, $bmajor, $bdate_len) = unpack('v v C', substr($r, 0, 5));
    my $p = 5;
    my $bdate = substr($r, $p, $bdate_len); $p += $bdate_len;
    my ($tminor, $tmajor, $tdate_len) = unpack('v v C', substr($r, $p, 5)); $p += 5;
    my $tdate = substr($r, $p, $tdate_len);
    $tdate =~ s/\0+$//;
    return {
        boot_major => $bmajor, boot_minor => $bminor, boot_date => $bdate,
        target_major => $tmajor, target_minor => $tminor, target_date => $tdate,
    };
}

sub serial_number {
    my ($self) = @_;
    my $s = $self->read_vs(VS_SERIAL_NUMBER);
    return defined $s ? $s : '(unknown)';
}

sub configuration {
    my ($self) = @_;
    return $self->read_vs(VS_CONFIGURATION);   # CP1251 text, "key=value" lines
}

# Read and decode the device's buffered record stream (VS DATA_BUF).
sub data_buf_raw {
    my ($self) = @_;
    return $self->read_vs(VS_DATA_BUF);   # undef on failure
}

# ============================================================================
# DATA_BUF decoder (pure function, no I/O)
# ============================================================================

# Record header: [seq u8][eid u8][gid u8][ts_offset i32], ts unit = 10 ms.
# Returns a list of hashrefs. Stops at the first sequence discontinuity or unknown record.
sub decode_data_buf {
    my ($data, $base_time) = @_;
    my @out;
    my $pos = 0;
    my $next_seq;

    while (length($data) - $pos >= 7) {
        my ($seq, $eid, $gid, $ts) = unpack('C C C l<', substr($data, $pos, 7));
        $pos += 7;
        my $t = $base_time + $ts * 0.01;

        if (defined $next_seq && $next_seq != $seq) {
            last;
        }
        $next_seq = ($seq + 1) % 256;

        if ($eid == 0) {
            # gid => [unpack format, payload size in bytes]
            # Perl pack formats: f< = LE float, V = LE u32, v = LE u16, C = u8.
            my %layout = (
                0 => ['f<f<vvvC', 15],   # RealTimeData
                1 => ['f<f<',      8],   # RawData
                2 => ['Vf<f<vv',  16],   # DoseRateDB
                3 => ['Vf<vvv',   14],   # RareData
                4 => ['Vf<f<vv',  16],   # UserData (consumed, not reported)
                5 => ['Vf<f<vv',  16],   # ScheduleData (consumed, not reported)
                6 => ['vvv',       6],   # AccelData (consumed, not reported)
                7 => ['CCv',       4],   # Event
                8 => ['f<v',       6],   # RawCountRate (consumed, not reported)
                9 => ['f<v',       6],   # RawDoseRate (consumed, not reported)
            );
            my $lay = $layout{$gid} or last;
            my ($rec_fmt, $sz) = @$lay;
            last if length($data) - $pos < $sz;
            my @f = unpack($rec_fmt, substr($data, $pos, $sz));
            $pos += $sz;

            if ($gid == 0) {
                push @out, { type => 'realtime', time => $t,
                    count_rate => $f[0], dose_rate => $f[1],
                    count_rate_err => $f[2] / 10, dose_rate_err => $f[3] / 10,
                    flags => $f[4], rt_flags => $f[5] };
            } elsif ($gid == 1) {
                push @out, { type => 'raw', time => $t, count_rate => $f[0], dose_rate => $f[1] };
            } elsif ($gid == 2) {
                push @out, { type => 'dose_db', time => $t, count => $f[0],
                    count_rate => $f[1], dose_rate => $f[2],
                    dose_rate_err => $f[3] / 10, flags => $f[4] };
            } elsif ($gid == 3) {
                push @out, { type => 'rare', time => $t, duration => $f[0], dose => $f[1],
                    temperature => ($f[2] - 2000) / 100, charge_level => $f[3] / 100,
                    flags => $f[4] };
            } elsif ($gid == 7) {
                push @out, { type => 'event', time => $t, event => $f[0],
                    event_param1 => $f[1], flags => $f[2] };
            }
            # other eid=0 groups: consumed, not reported
        } elsif ($eid == 1 && $gid >= 1 && $gid <= 3) {
            my $per = { 1 => 8, 2 => 16, 3 => 14 }->{$gid};
            last if length($data) - $pos < 6;
            my ($n, $smpl_ms) = unpack('v V', substr($data, $pos, 6));
            $pos += 6 + $per * $n;   # skip spectrum-like sample blocks
        } else {
            last;   # unknown record type: cannot resynchronise safely
        }
    }
    return @out;
}

# ============================================================================
# Commands
# ============================================================================

sub print_info {
    my ($self) = @_;
    my $ver = $self->fw_version();
    print "Serial:       ", $self->serial_number(), "\n";
    if ($ver) {
        printf "Firmware:     target %d.%d (%s), boot %d.%d (%s)\n",
            $ver->{target_major}, $ver->{target_minor}, $ver->{target_date},
            $ver->{boot_major},   $ver->{boot_minor},   $ver->{boot_date};
    } else {
        print STDERR "ERROR: could not read firmware version\n";
        return 1;
    }
    return 0;
}

sub print_config {
    my ($self) = @_;
    my $cfg = $self->configuration();
    unless (defined $cfg) {
        print STDERR "ERROR: could not read configuration\n";
        return 1;
    }
    print $cfg;
    print "\n" unless $cfg =~ /\n\z/;
    return 0;
}

sub print_buffer {
    my ($self) = @_;
    my $raw = $self->data_buf_raw();
    unless (defined $raw) {
        print STDERR "ERROR: could not read data buffer\n";
        return 1;
    }
    my @recs = decode_data_buf($raw, $self->{base_time});
    unless (@recs) {
        print "(no records)\n";
        return 0;
    }
    for my $r (@recs) {
        print format_record($r), "\n";
    }
    return 0;
}

# Poll the buffer and print realtime readings. count=0 means run until interrupted.
sub live {
    my ($self, $interval, $count) = @_;
    my $printed = 0;
    print "time                 cps        dose_rate(raw)  cps_err%  dose_err%\n";
    while (1) {
        my $raw = $self->data_buf_raw();
        unless (defined $raw) {
            print STDERR "ERROR: could not read data buffer\n";
            return 1;
        }
        my @recs = grep { $_->{type} eq 'realtime' } decode_data_buf($raw, $self->{base_time});
        for my $r (@recs) {
            printf "%-20s %-10.2f %-15.4f %-9.1f %.1f\n",
                strftime('%Y-%m-%d %H:%M:%S', localtime($r->{time})),
                $r->{count_rate}, $r->{dose_rate},
                $r->{count_rate_err}, $r->{dose_rate_err};
            $printed++;
            last if $count && $printed >= $count;
        }
        last if $count && $printed >= $count;
        select(undef, undef, undef, $interval);
    }
    return 0;
}

sub format_record {
    my ($r) = @_;
    my $ts = strftime('%Y-%m-%d %H:%M:%S', localtime($r->{time}));
    my $t = $r->{type};
    return "$ts  realtime  cps=$r->{count_rate} dose=$r->{dose_rate} flags=$r->{flags}"
        if $t eq 'realtime';
    return "$ts  raw       cps=$r->{count_rate} dose=$r->{dose_rate}" if $t eq 'raw';
    return "$ts  dose_db   count=$r->{count} cps=$r->{count_rate} dose=$r->{dose_rate}" if $t eq 'dose_db';
    return "$ts  rare      duration=$r->{duration}s dose=$r->{dose} temp=$r->{temperature}C charge=$r->{charge_level}%"
        if $t eq 'rare';
    return "$ts  event     id=$r->{event} param=$r->{event_param1}" if $t eq 'event';
    return "$ts  $t";
}

sub debug {
    my ($self, $msg) = @_;
    print STDERR "  [DEBUG] $msg\n" if $self->{debug};
}

1;

# ============================================================================
# Main package helpers
# ============================================================================

package main;

sub print_usage {
    print <<"EOF";
Usage: $0 -d AA:BB:CC:DD:EE:FF [actions] [options]

Actions (default: live realtime readings):
  --info          Show serial number and firmware version
  --config        Dump device configuration (text)
  --buffer        Dump all buffered records once
  (none)          Poll realtime count/dose rate; Ctrl-C to stop

Options:
  -d, --device ADDR        BLE address of the RadiaCode (required)
  -i, --interval SEC       Poll interval for live mode (default: 2)
  -n, --count N            Stop live mode after N readings (default: forever)
  --addr-type TYPE         public|random (default: public)
  --connect-timeout SEC    Connect timeout in seconds (default: 5)
  --write-uuid UUID        Write characteristic (default: e63215e6-7003-49d8-96b0-b024798fb901)
  --notify-uuid UUID       Notify characteristic (default: e63215e7-7003-49d8-96b0-b024798fb901)
  -v, --debug              Verbose protocol trace (repeat for more)
  -h, --help               Show this help

Examples:
  $0 -d 52:43:01:02:03:04 --info
  $0 -d 52:43:01:02:03:04 --interval 1 -n 20
EOF
}
