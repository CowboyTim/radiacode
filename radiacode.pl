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
#   ./radiacode.pl -d AA:BB:CC:DD:EE:FF --info                 # serial and firmware
#   ./radiacode.pl -d AA:BB:CC:DD:EE:FF --status               # live status registers
#   ./radiacode.pl -d AA:BB:CC:DD:EE:FF --config               # device configuration text
#   ./radiacode.pl -d AA:BB:CC:DD:EE:FF --buffer               # dump buffered records once
#   ./radiacode.pl -d AA:BB:CC:DD:EE:FF                        # live readings (Ctrl-C to stop)
#   ./radiacode.pl -d AA:BB:CC:DD:EE:FF -i 5 -n 10 --format csv -o readings.csv
#
# NOTE: The RadiaCode must not be connected to another host (e.g. the phone app) at the same time.

use strict;
use warnings;
use bytes;
use Getopt::Long;
use POSIX qw(strftime);
use JSON::PP ();

# Command-line entry point. Wrapped in a sub so the file can be required by tests
# (see the guard at the end of the file).
sub run_cli {
my %opts = (
    device            => undef,
    addr_type         => 'public',
    connect_timeout   => 5,
    debug             => 0,
    write_uuid        => 'e63215e6-7003-49d8-96b0-b024798fb901',
    notify_uuid       => 'e63215e7-7003-49d8-96b0-b024798fb901',
    interval          => 2,
    count             => 0,
    dir               => undef,
    spectrum_every    => 0,
    format            => 'text',
    output            => undef,
    backfill          => 0,
);

my ($do_info, $do_config, $do_buffer, $do_status, $do_spectrum, $do_accum,
    $do_alarms, $do_settings) = (0) x 8;
my $do_monitor = 0;
my $plot_dir;   # undef = not requested; '' = use --dir (or ./radiacode-data)
my $do_spectrum_reset = 0;
my $do_poweroff = 0;
my $do_energy_calib = 0;
my $set_energy_calib;   # 'a0,a1,a2' to write
my @set_args;   # --set NAME=VALUE, repeatable
my $set_time;   # undef = not requested; '' or 'now' = host clock; or 'YYYY-MM-DD HH:MM:SS'

GetOptions(
    'device|d=s'        => \$opts{device},
    'addr-type=s'       => \$opts{addr_type},
    'connect-timeout=f' => \$opts{connect_timeout},
    'write-uuid=s'      => \$opts{write_uuid},
    'notify-uuid=s'     => \$opts{notify_uuid},
    'interval|i=f'      => \$opts{interval},
    'count|n=i'         => \$opts{count},
    'format|f=s'        => \$opts{format},
    'output|o=s'        => \$opts{output},
    'backfill'          => \$opts{backfill},
    'info'              => \$do_info,
    'status'            => \$do_status,
    'spectrum'          => \$do_spectrum,
    'accum'             => \$do_accum,
    'alarms'            => \$do_alarms,
    'settings'          => \$do_settings,
    'set-time:s'        => \$set_time,
    'spectrum-reset'    => \$do_spectrum_reset,
    'set=s@'            => \@set_args,
    'poweroff'          => \$do_poweroff,
    'energy-calib'      => \$do_energy_calib,
    'set-energy-calib=s' => \$set_energy_calib,
    'monitor'           => \$do_monitor,
    'plot:s'            => \$plot_dir,
    'dir=s'             => \$opts{dir},
    'spectrum-every=f'  => \$opts{spectrum_every},
    'config'            => \$do_config,
    'buffer'            => \$do_buffer,
    'debug|v+'          => \$opts{debug},
    'man'               => sub { show_man() },
    'help|h'            => sub { show_manual() },
) or usage_error();

# --plot needs no device: it only reads the CSV logs from --monitor.
if (defined $plot_dir) {
    my $dir = length($plot_dir) ? $plot_dir : ($opts{dir} // './radiacode-data');
    my $rc = eval { RadiaCode::Plot::run($dir) };
    unless (defined $rc) {
        print STDERR "ERROR: $@";
        exit 1;
    }
    exit 0;
}

unless ($opts{device}) {
    print STDERR "Error: -d / --device is required\n";
    usage_error();
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
if ($opts{format} !~ /^(?:text|csv|json)$/) {
    print STDERR "Error: --format must be text, csv or json\n";
    exit 1;
}

my $rc_dev = RadiaCode::BLE->new(%opts);
exit $rc_dev->run(
    info     => $do_info,
    status   => $do_status,
    spectrum => $do_spectrum,
    accum    => $do_accum,
    alarms   => $do_alarms,
    settings => $do_settings,
    set_time => $set_time,
    spectrum_reset => $do_spectrum_reset,
    poweroff       => $do_poweroff,
    energy_calib   => $do_energy_calib,
    set_energy_calib => $set_energy_calib,
    set            => \@set_args,
    config   => $do_config,
    buffer   => $do_buffer,
    count    => $opts{count},
    interval => $opts{interval},
    monitor        => $do_monitor,
    dir            => $opts{dir},
    spectrum_every => $opts{spectrum_every},
);
}

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
    CMD_GET_STATUS            => 0x0005,
    CMD_GET_VERSION           => 0x000A,
    CMD_GET_SERIAL            => 0x000B,
    CMD_SET_EXCHANGE          => 0x0007,
    CMD_SET_TIME              => 0x0A04,
    CMD_WR_VIRT_SFR           => 0x0825,
    CMD_RD_VIRT_SFR_BATCH     => 0x082A,
    CMD_RD_VIRT_STRING        => 0x0826,
    CMD_WR_VIRT_STRING        => 0x0827,

    # Virtual strings
    VS_CONFIGURATION          => 0x0002,
    VS_SERIAL_NUMBER          => 0x0008,
    VS_DATA_BUF               => 0x0100,
    VS_SPECTRUM               => 0x0200,
    VS_SPEC_ACCUM             => 0x0205,
    VS_ENERGY_CALIB           => 0x0202,

    # Virtual SFRs
    VSFR_DEVICE_TIME          => 0x0504,

    ATT_CHUNK                 => 18,   # max payload per Write Command, as used by cdump/radiacode
    RESPONSE_TIMEOUT          => 10.0,
    SEEN_LIMIT                => 20000, # de-dup memory cap for live mode
};

# Registers read by --status: name => [VSFR id, perl unpack template applied to the
# 4-byte little-endian register value]. Templates follow cdump/radiacode _VSFR_FORMATS.
# These are set in BEGIN blocks because the main program (which calls run()) appears
# above this package in the file, so plain file-scope assignments would not have run yet.
my (%STATUS_VSFR, @CSV_COLS, %EVENT_NAME, @CTRL_NAME);
BEGIN {
    %STATUS_VSFR = (
        device_on   => [0x0503, 'V'],       # DEVICE_ON   (value is in the low byte; nonzero = on)
        cps         => [0x8020, 'V'],       # CPS         (counts per second)
        dr_uR_h     => [0x8021, 'V'],       # DR_uR_h     (dose rate, micro-R/h)
        ds_uR       => [0x8022, 'V'],       # DS_uR       (accumulated dose, micro-R)
        temp_c      => [0x8024, 'f<'],      # TEMP_degC   (float)
        acc_x       => [0x8025, 's<'],      # ACC_X       (int16, low bytes)
        acc_y       => [0x8026, 's<'],      # ACC_Y
        acc_z       => [0x8027, 's<'],      # ACC_Z
    );

    # Column order for CSV output.
    @CSV_COLS = qw(time type count count_rate count_rate_err dose_rate dose_rate_err
                   flags rt_flags duration dose temperature charge_level event event_name event_param1);

    # Per-event sound/vibration bits (SOUND_CTRL 0x0520, VIBRO_CTRL 0x0530). Bits 0-7 are
    # cdump's CTRL enum. Bits 8-12 appear on firmware 4.15; bits 10-12 are named from menu checks.
    @CTRL_NAME = (
        'buttons', 'particle-registration', 'dose-rate-alarm-1', 'dose-rate-alarm-2', 'dose-rate-off-scale',
        'dose-alarm-1', 'dose-alarm-2', 'dose-off-scale',
        'connect-disconnect', 'power-on-off', # bits 8 and 9: sound for connect/disconnect and power on/off (menu checks)
        'count-rate-alarm-1',           # bit 10: vibration (menu check)
        'count-rate-alarm-2',           # bit 11: vibration on, sound turned on (menu check)
        'count-rate-off-scale',         # bit 12: vibration (menu check)
        map { "bit$_" } 13 .. 31,
    );

    # Device event ids (cdump EventId). Alarm events are DOSE_RATE_ALARM1/2 (9, 10),
    # DOSE_ALARM1/2 (12, 13), COUNT_RATE_ALARM1/2 (20, 21) and the OFFSCALE events.
    %EVENT_NAME = (
        0 => 'POWER_OFF', 1 => 'POWER_ON', 2 => 'LOW_BATTERY_SHUTDOWN',
        3 => 'CHANGE_DEVICE_PARAMS', 4 => 'DOSE_RESET', 5 => 'USER_EVENT',
        6 => 'BATTERY_EMPTY_ALARM', 7 => 'CHARGE_START', 8 => 'CHARGE_STOP',
        9 => 'DOSE_RATE_ALARM1', 10 => 'DOSE_RATE_ALARM2', 11 => 'DOSE_RATE_OFFSCALE',
        12 => 'DOSE_ALARM1', 13 => 'DOSE_ALARM2', 14 => 'DOSE_OFFSCALE',
        15 => 'TEMPERATURE_TOO_LOW', 16 => 'TEMPERATURE_TOO_HIGH', 17 => 'TEXT_MESSAGE',
        18 => 'MEMORY_SNAPSHOT', 19 => 'SPECTRUM_RESET',
        20 => 'COUNT_RATE_ALARM1', 21 => 'COUNT_RATE_ALARM2', 22 => 'COUNT_RATE_OFFSCALE',
    );
}

# Set by the SIGINT/SIGTERM handler; checked by the monitor loop.
our $MONITOR_STOP = 0;

sub event_name {
    my ($id) = @_;
    return $EVENT_NAME{$id} // "EVENT_$id";
}

sub new {
    my ($class, %o) = @_;
    bless {
        device          => $o{device},
        addr_type       => lc($o{addr_type} // 'public'),
        connect_timeout => $o{connect_timeout} // 5,
        debug           => $o{debug} // 0,
        write_uuid      => lc($o{write_uuid}  // 'e63215e6-7003-49d8-96b0-b024798fb901'),
        notify_uuid     => lc($o{notify_uuid} // 'e63215e7-7003-49d8-96b0-b024798fb901'),
        format          => $o{format} // 'text',
        output          => $o{output},
        backfill        => $o{backfill} // 0,

        socket          => undef,
        out             => \*STDOUT,
        csv_header_due  => 1,
        json            => JSON::PP->new->canonical(1),
        seen            => {},
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

    # Output destination for measurement records (status/info/config go to STDOUT).
    if (defined $self->{output}) {
        my $file = $self->{output};
        my $existed_nonempty = (-s $file) ? 1 : 0;
        open(my $fh, '>>', $file) or do {
            print STDERR "ERROR: cannot open output file '$file': $!\n";
            return 1;
        };
        $fh->autoflush(1);
        $self->{out} = $fh;
        $self->{csv_header_due} = $existed_nonempty ? 0 : 1;
    }

    print STDERR "Device: $self->{device}\n";

    if ($todo{monitor}) {
        return $self->monitor(%todo);
    }

    return 1 unless $self->open_session();

    my $rc = 1;
    eval {
        $rc = 0;
        if (defined $todo{set_time}) {
            $rc |= $self->print_set_time($todo{set_time});
        }
        for my $pair (@{ $todo{set} || [] }) {
            my ($name, $value) = split /=/, $pair, 2;
            unless (defined $value) {
                print STDERR "ERROR: --set expects NAME=VALUE, got '$pair'\n";
                $rc = 1;
                next;
            }
            $rc = 1 unless $self->set_setting($name, $value);
        }
        if ($todo{energy_calib}) {
            $rc |= $self->print_energy_calib();
        }
        if (defined $todo{set_energy_calib}) {
            $rc |= $self->print_set_energy_calib($todo{set_energy_calib});
        }
        if ($todo{poweroff}) {
            $rc |= $self->print_poweroff();
        }
        if ($todo{spectrum_reset}) {
            $rc |= $self->print_spectrum_reset();
        }
        if ($todo{info}) {
            $rc |= $self->print_info();
        }
        if ($todo{status}) {
            $rc |= $self->print_status();
        }
        if ($todo{spectrum}) {
            $rc |= $self->print_spectrum($todo{accum});
        }
        if ($todo{alarms}) {
            $rc |= $self->print_alarms();
        }
        if ($todo{settings}) {
            $rc |= $self->print_settings();
        }
        if ($todo{config}) {
            $rc |= $self->print_config();
        }
        if ($todo{buffer}) {
            $rc |= $self->print_buffer();
        }
        if (!$todo{info} && !$todo{status} && !$todo{config} && !$todo{buffer} && !$todo{spectrum}
            && !$todo{alarms} && !$todo{settings} && !defined $todo{set_time}
            && !$todo{spectrum_reset} && !$todo{poweroff} && !$todo{energy_calib}
            && !defined $todo{set_energy_calib} && !@{ $todo{set} || [] }) {
            $rc |= $self->live($todo{interval}, $todo{count});
        }
        1;
    } or do {
        print STDERR "ERROR: $@" if $@ && $@ ne "discover\n" && $@ ne "cccd\n" && $@ ne "init\n";
        $rc = 1;
    };

    $self->ble_disconnect();
    close($self->{out}) if defined $self->{output};
    return $rc;
}

# ============================================================================
# BLE connection (raw L2CAP ATT channel, CID 4)
# ============================================================================

# Connect, discover handles, enable notifications and initialise the device.
# Returns true when the device is ready. On failure the link is closed again.
sub open_session {
    my ($self) = @_;
    unless ($self->ble_connect()) {
        print STDERR "ERROR: BLE connection failed\n";
        return 0;
    }
    unless ($self->discover_handles()) {
        print STDERR "ERROR: RadiaCode write/notify characteristics not found\n";
        $self->ble_disconnect();
        return 0;
    }
    unless ($self->subscribe_notify()) {
        print STDERR "ERROR: Could not enable notifications (CCCD)\n";
        $self->ble_disconnect();
        return 0;
    }
    unless ($self->init_device()) {
        print STDERR "ERROR: Device initialisation failed (is another host connected?)\n";
        $self->ble_disconnect();
        return 0;
    }
    return 1;
}

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
    my $start = 0x0001;

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
# echo), or undef on error/timeout. An empty body is returned as '' (defined).
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

# Batch-read registers. Returns one raw u32 per id, or undef for a register the device
# reports as invalid (the firmware does not expose every register). Empty list on
# transport failure. Request: [n][id...]. Response: [valid-bitmask u32][value u32 ...].
sub read_vsfrs_raw {
    my ($self, @ids) = @_;
    my $n = scalar @ids;
    return () unless $n;
    my $r = $self->execute(CMD_RD_VIRT_SFR_BATCH, pack('V', $n) . join('', map { pack('V', $_) } @ids))
        or return ();
    return () unless length($r) >= 4;
    my $flags = unpack('V', substr($r, 0, 4));
    # Values are sent only for the valid registers, in request order.
    my @vals  = unpack('V*', substr($r, 4));
    $self->debug(sprintf('batch read: validity mask %0*b for %d ids, %d values',
        $n, $flags, $n, scalar @vals));
    my ($out, @res) = (0);
    for my $i (0 .. $n - 1) {
        if (($flags >> $i) & 1) {
            push @res, $vals[$out++];
        } else {
            push @res, undef;
        }
    }
    return @res;
}

# Send a clock value to the device. The device takes local date/time fields (no zone),
# so the fields come from localtime($epoch). Also resets the device time counter to 0,
# as cdump does after SET_TIME. Returns true on success.
sub send_clock {
    my ($self, $epoch) = @_;
    my @t = localtime($epoch);
    my $tm = pack('C8', $t[3], $t[4] + 1, ($t[5] + 1900) - 2000, 0, $t[0], $t[1], $t[2], 0);
    defined $self->execute(CMD_SET_TIME, $tm) or return 0;
    return $self->write_vsfr(VSFR_DEVICE_TIME, pack('V', 0)) ? 1 : 0;
}

# --set-time: write a clock value to the device. Value 'now' (or empty) uses the host
# clock; otherwise 'YYYY-MM-DD HH:MM:SS' is taken as the device's local time.
# ---- Device writes: --set NAME=VALUE ----
# encode_setting() turns a user value into (register id, raw register value). It is a pure
# function so it can be tested without a device. $ctx carries the device unit switches:
#   cr_cpm: 1 when count-rate alarms are shown in cpm (stored as cps * 10 either way)
#   ds_sv:  1 when dose values are in Sv (stored as micro-units * 100); 0 for R (micro-R)
sub _round { my $x = shift; return $x < 0 ? -int(-$x + 0.5) : int($x + 0.5) }

sub encode_setting {
    my ($name, $value, $ctx) = @_;
    $ctx //= { cr_cpm => 0, ds_sv => 0 };
    my $num = sub {
        my $v = shift;
        die "expects a number\n" unless defined $v && $v =~ /^-?\d+(?:\.\d+)?$/;
        return $v + 0;
    };
    my $onoff = sub {
        my $v = lc($_[0] // '');
        return 1 if $v eq 'on';
        return 0 if $v eq 'off';
        die "expects on or off\n";
    };

    if ($name eq 'brightness') {
        my $v = $num->($value);
        die "must be 0-9\n" unless $v == int($v) && $v >= 0 && $v <= 9;
        return (0x0511, $v);
    }
    if ($name eq 'display-off') {
        my $v = $num->($value);
        # Only these four map to distinct device values (20 s and 30 s share raw 3).
        die "must be 5, 10, 15 or 30 seconds\n" unless grep { $v == $_ } 5, 10, 15, 30;
        return (0x0513, $v == 30 ? 3 : $v / 5 - 1);     # inverse of the read side
    }
    if ($name eq 'direction') {
        my %d = (auto => 0, normal => 1, right => 1, rotated => 2, left => 2);
        die "must be auto, normal or rotated\n" unless exists $d{lc($value // '')};
        return (0x0515, $d{lc $value});
    }
    if ($name eq 'backlight') { return (0x0516, $onoff->($value)) }
    if ($name eq 'sound')     { return (0x0522, $onoff->($value)) }
    if ($name eq 'vibration') { return (0x0531, $onoff->($value)) }
    if ($name eq 'alarm-mode') {
        my %m = (continuous => 0, once => 1);
        die "must be continuous or once\n" unless exists $m{lc($value // '')};
        return (0x05E0, $m{lc $value});
    }

    if ($name =~ /^alarm-(count|dose-rate|dose)-([12])$/) {
        my ($kind, $lvl) = ($1, $2);
        my $v = $num->($value);
        if ($kind eq 'count') {
            my $cps = $ctx->{cr_cpm} ? $v / 60 : $v;     # value is in the device's count unit
            die "must be 0.1 to 50000 cps\n" unless $cps >= 0.1 && $cps <= 50e3;
            return ($lvl == 1 ? 0x8008 : 0x8009, _round($cps * 10));
        }
        # dose-rate: uSv/h (Sv) or uR/h; dose: uSv (Sv) or uR. Raw = micro-unit * 100 for Sv.
        my $mult = $ctx->{ds_sv} ? 100 : 1;
        my $raw  = _round($v * $mult);
        die "must be 0 or more\n" if $v < 0;
        die "value too large for the device\n" if $raw > 999999999;
        if ($kind eq 'dose-rate') {
            return ($lvl == 1 ? 0x8000 : 0x8001, $raw);
        }
        return ($lvl == 1 ? 0x8014 : 0x8015, $raw);
    }
    die "unknown setting '$name'\n";
}

# Observed on RC-110 (fw 4.14): lowering dose alarm 2 below dose alarm 1 also lowers
# dose alarm 1 to match, so alarm 1 never sits above alarm 2. Set alarm 2 first when
# lowering both, and check --alarms afterwards.
# Turn one per-event sound or vibration bit on or off (read-modify-write of the whole
# register, so the other events keep their state). Returns true when read back as sent.
sub set_event_bit {
    my ($self, $kind, $event, $value) = @_;
    my $id = $kind eq 'sound' ? 0x0520 : 0x0530;
    my $on = lc($value // '') eq 'on' ? 1 : lc($value // '') eq 'off' ? 0 : undef;
    unless (defined $on) {
        print STDERR "ERROR: $kind-$event=$value: expects on or off\n";
        return 0;
    }
    my ($old) = $self->read_vsfrs_raw($id);
    unless (defined $old) {
        print STDERR "ERROR: $kind-$event: could not read the current mask\n";
        return 0;
    }
    my $bitpos = (grep { $CTRL_NAME[$_] eq $event } 0 .. $#CTRL_NAME)[0];
    my $new = $on ? ($old | (1 << $bitpos)) : ($old & ~(1 << $bitpos)) & 0xFFFFFFFF;
    unless ($self->write_vsfr($id, pack('V', $new))) {
        print STDERR "ERROR: $kind-$event: the device rejected the write\n";
        return 0;
    }
    my ($read) = $self->read_vsfrs_raw($id);
    my $ok = defined $read && $read == $new;
    printf "%-20s mask 0x%X -> 0x%X (device reads 0x%X) %s\n", "$kind-$event:",
        $old, $new, $read // 0, $ok ? 'OK' : 'MISMATCH';
    return $ok ? 1 : 0;
}

# Write one setting, read it back and report. Returns true when the device reads back
# the value that was written.
sub set_setting {
    my ($self, $name, $value) = @_;
    if ($name =~ /^(sound|vibration)-(.+)$/ && grep { $_ eq $2 } @CTRL_NAME) {
        return $self->set_event_bit($1, $2, $value);
    }
    my @units = $self->read_vsfrs_raw(0x8013, 0x8004);     # CR_UNITS, DS_UNITS
    my $ctx = {
        cr_cpm => (defined $units[0] && $units[0]) ? 1 : 0,
        ds_sv  => (defined $units[1] && $units[1]) ? 1 : 0,
    };
    my ($id, $raw) = eval { encode_setting($name, $value, $ctx) };
    unless (defined $id) {
        my $err = $@ || "invalid value\n";
        $err =~ s/\n\z//;
        print STDERR "ERROR: $name=$value: $err\n";
        return 0;
    }
    my ($old) = $self->read_vsfrs_raw($id);
    unless ($self->write_vsfr($id, pack('V', $raw))) {
        print STDERR "ERROR: $name: the device rejected the write\n";
        return 0;
    }
    my ($new) = $self->read_vsfrs_raw($id);
    my $ok = defined $new && $new == $raw;
    printf "%-20s raw %s -> %s (device reads %s) %s\n", "$name:",
        $old // 'n/a', $raw, $new // 'n/a', $ok ? 'OK' : 'MISMATCH';
    return $ok ? 1 : 0;
}

# Energy calibration (VS 0x0202): three little-endian floats a0, a1, a2. Channel to keV is
# a0 + a1*ch + a2*ch^2 (see channel_to_keV). Read: read_vs. Write: WR_VIRT_STRING with the
# id, the length and the three floats; retcode 1 on success.
sub read_energy_calib {
    my ($self) = @_;
    my $raw = $self->read_vs(VS_ENERGY_CALIB) or return;
    return unless length($raw) == 12;
    return unpack('f<f<f<', $raw);
}

sub write_energy_calib {
    my ($self, @coef) = @_;
    my $pc = pack('f<f<f<', @coef);
    my $r = $self->execute(CMD_WR_VIRT_STRING, pack('V V', VS_ENERGY_CALIB, length $pc) . $pc)
        or return 0;
    return length($r) >= 4 && unpack('V', substr($r, 0, 4)) == 1;
}

sub print_energy_calib {
    my ($self) = @_;
    my @c = $self->read_energy_calib();
    unless (@c) {
        print STDERR "ERROR: could not read the energy calibration\n";
        return 1;
    }
    # 9 significant digits round-trip a 32-bit float, so this output can be written back exactly.
    printf "Energy calibration: a0=%.9g keV  a1=%.9g keV/ch  a2=%.9g keV/ch^2\n", @c;
    printf "Write back with: --set-energy-calib %.9g,%.9g,%.9g\n", @c;
    return 0;
}

# --set-energy-calib A0,A1,A2: write the three coefficients and read them back.
sub print_set_energy_calib {
    my ($self, $value) = @_;
    my @coef = split /,/, $value // '';
    unless (@coef == 3 && !grep { !/^-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?$/ } @coef) {
        print STDERR "ERROR: --set-energy-calib expects A0,A1,A2 (three numbers)\n";
        return 1;
    }
    @coef = map { $_ + 0 } @coef;
    unless ($self->write_energy_calib(@coef)) {
        print STDERR "ERROR: the device rejected the energy calibration\n";
        return 1;
    }
    my @back = $self->read_energy_calib();
    my $ok = @back == 3 && !grep { abs($back[$_] - $coef[$_]) > 1e-6 * (1 + abs($coef[$_])) } 0 .. 2;
    printf "Energy calibration written: a0=%s a1=%s a2=%s (device reads %s) %s\n",
        @coef, join(',', map { defined $_ ? $_ : 'n/a' } @back), $ok ? 'OK' : 'MISMATCH';
    return $ok ? 0 : 1;
}

# Power the device down (DEVICE_ON = 0). It then needs its own button to wake, and BLE is
# unavailable until then. Reads back the register before reporting.
sub print_poweroff {
    my ($self) = @_;
    my ($old) = $self->read_vsfrs_raw(0x0503);
    unless ($self->write_vsfr(0x0503, pack('V', 0))) {
        print STDERR "ERROR: the device rejected the power-off\n";
        return 1;
    }
    my ($new) = $self->read_vsfrs_raw(0x0503);
    if (defined $new && $new == 0) {
        print "Device powered off (was " . ($old ? 'on' : 'off') . "). Press its button to wake it.\n";
        return 0;
    }
    print STDERR "ERROR: device still reads on after the power-off\n";
    return 1;
}

# Clear the device's current (cumulative) spectrum. Command 0x0827 (WR_VIRT_STRING) with
# the spectrum id and a zero length, as cdump's spectrum_reset(). The device answers with
# retcode 1 and no payload on success.
sub print_spectrum_reset {
    my ($self) = @_;
    my $r = $self->execute(CMD_WR_VIRT_STRING, pack('V V', VS_SPECTRUM, 0));
    unless (defined $r && length($r) == 4 && unpack('V', $r) == 1) {
        print STDERR "ERROR: spectrum reset failed\n";
        return 1;
    }
    print "Spectrum reset: the current spectrum now starts from zero\n";
    return 0;
}

sub print_set_time {
    my ($self, $value) = @_;
    my $epoch;
    if (!defined $value || $value eq '' || $value eq 'now') {
        $epoch = time();
    } elsif ($value =~ /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)$/) {
        $epoch = POSIX::mktime($6, $5, $4, $3, $2 - 1, $1 - 1900);
    }
    unless (defined $epoch) {
        print STDERR "ERROR: --set-time expects 'now' or 'YYYY-MM-DD HH:MM:SS'\n";
        return 1;
    }
    unless ($self->send_clock($epoch)) {
        print STDERR "ERROR: could not set device time\n";
        return 1;
    }
    print "Device time set to ", strftime('%Y-%m-%d %H:%M:%S', localtime($epoch)),
          " (local fields sent as-is)\n";
    return 0;
}

# Handshake, time sync and base time (mirrors cdump/radiacode RadiaCode.__init__).
sub init_device {
    my ($self) = @_;

    # execute() returns '' (not undef) for a valid empty body, so test definedness.
    defined $self->execute(CMD_SET_EXCHANGE, "\x01\xff\x12\xff") or return 0;

    $self->send_clock(time()) or return 0;
    # The device's record counter starts at zero when it is set, so record time = connect time + ts.
    # (cdump adds 128 s; on RC-110 fw 4.14/4.15 that put records two minutes in the future.)
    $self->{base_time} = time();
    $self->{start_time} = time();

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

sub data_buf_raw {
    my ($self) = @_;
    return $self->read_vs(VS_DATA_BUF);   # undef on failure
}

# Device status flags from GET_STATUS (u32), or undef.
sub status_flags {
    my ($self) = @_;
    my $r = $self->execute(CMD_GET_STATUS) or return;
    return unless length($r) >= 4;
    return unpack('V', substr($r, 0, 4));
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
                    event_name => event_name($f[0]),
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
# Spectrum decoder (pure function, no I/O)
# ============================================================================

# Format version 0: plain u32 counts.
sub decode_counts_v0 {
    my ($data) = @_;
    return unpack('V*', $data);
}

# Format version 1: packed runs. Each u16 header = [count:12][vlen:4]; each sample is
# stored as a delta from the previous one, with width given by vlen (cdump decoders/spectrum.py).
sub decode_counts_v1 {
    my ($data) = @_;
    my @counts;
    my ($last, $pos) = (0, 0);
    my $len = length $data;
    while ($pos < $len) {
        die "truncated spectrum header\n" if $pos + 2 > $len;
        my $u16  = unpack('v', substr($data, $pos, 2));
        $pos += 2;
        my $cnt  = ($u16 >> 4) & 0x0FFF;
        my $vlen = $u16 & 0x0F;
        for (1 .. $cnt) {
            my $v;
            if ($vlen == 0) {
                $v = 0;
            } elsif ($vlen == 1) {
                die "truncated spectrum\n" if $pos + 1 > $len;
                $v = unpack('C', substr($data, $pos, 1)); $pos += 1;
            } elsif ($vlen == 2) {
                die "truncated spectrum\n" if $pos + 1 > $len;
                $v = $last + unpack('c', substr($data, $pos, 1)); $pos += 1;
            } elsif ($vlen == 3) {
                die "truncated spectrum\n" if $pos + 2 > $len;
                $v = $last + unpack('s<', substr($data, $pos, 2)); $pos += 2;
            } elsif ($vlen == 4) {
                die "truncated spectrum\n" if $pos + 3 > $len;
                my ($a, $b, $c) = unpack('CCc', substr($data, $pos, 3)); $pos += 3;
                $v = $last + $c * 65536 + $b * 256 + $a;   # c is signed
            } elsif ($vlen == 5) {
                die "truncated spectrum\n" if $pos + 4 > $len;
                $v = $last + unpack('l<', substr($data, $pos, 4)); $pos += 4;
            } else {
                die "unsupported spectrum vlen=$vlen\n";
            }
            $last = $v;
            push @counts, $v;
        }
    }
    return @counts;
}

# Decode a VS SPECTRUM/SPEC_ACCUM blob: [duration u32 s][a0 f][a1 f][a2 f][counts...]
# Returns a hashref, or undef on a malformed blob.
sub decode_spectrum {
    my ($data, $format_version) = @_;
    return undef if length($data) < 16;
    my ($duration, $a0, $a1, $a2) = unpack('V f< f< f<', substr($data, 0, 16));
    my $body = substr($data, 16);
    my @counts = $format_version == 0 ? decode_counts_v0($body) : decode_counts_v1($body);
    return { duration_s => $duration, a0 => $a0, a1 => $a1, a2 => $a2, counts => \@counts };
}

# Quadratic channel-to-energy calibration (keV), as in cdump spectrum_channel_to_energy.
sub channel_to_keV {
    my ($ch, $a0, $a1, $a2) = @_;
    return $a0 + $a1 * $ch + $a2 * $ch * $ch;
}

# ============================================================================
# Commands
# ============================================================================

# Read and print the current (or accumulated) energy spectrum.
sub print_spectrum {
    my ($self, $accum) = @_;
    my $id = $accum ? VS_SPEC_ACCUM : VS_SPECTRUM;

    my $cfg = $self->configuration() // '';
    my ($fmt) = $cfg =~ /^SpecFormatVersion\s*=\s*(\d+)/m;
    $fmt //= 0;
    unless ($fmt == 0 || $fmt == 1) {
        print STDERR "ERROR: unsupported spectrum format version $fmt\n";
        return 1;
    }

    my $raw = $self->read_vs($id);
    unless (defined $raw) {
        print STDERR "ERROR: could not read spectrum\n";
        return 1;
    }
    my $s = eval { decode_spectrum($raw, $fmt) };
    unless ($s) {
        print STDERR "ERROR: could not decode spectrum: " . ($@ || 'malformed data') . "\n";
        return 1;
    }

    my @c = @{ $s->{counts} };
    my ($a0, $a1, $a2) = @{$s}{qw(a0 a1 a2)};
    my $total = 0; $total += $_ for @c;
    my ($peak_ch, $peak) = (0, -1);
    for my $i (0 .. $#c) { ($peak_ch, $peak) = ($i, $c[$i]) if $c[$i] > $peak; }

    my $fh = $self->{out};
    if ($self->{format} eq 'json') {
        my %j = (
            spectrum      => $accum ? 'accumulated' : 'current',
            format_version => $fmt,
            duration_s    => $s->{duration_s},
            calibration   => { a0 => $a0, a1 => $a1, a2 => $a2 },
            channels      => scalar(@c),
            total_counts  => $total,
            counts        => \@c,
        );
        print {$fh} $self->{json}->encode(\%j), "\n";
    } elsif ($self->{format} eq 'csv') {
        print {$fh} "channel,energy_keV,counts\n";
        for my $i (0 .. $#c) {
            printf {$fh} "%d,%.3f,%d\n", $i, channel_to_keV($i, $a0, $a1, $a2), $c[$i];
        }
    } else {
        printf "Spectrum:       %s (format v%d)\n", $accum ? 'accumulated' : 'current', $fmt;
        printf "Duration:       %d s\n", $s->{duration_s};
        printf "Calibration:    a0=%.4f a1=%.6f a2=%.9f\n", $a0, $a1, $a2;
        printf "Channels:       %d\n", scalar @c;
        printf "Total counts:   %d\n", $total;
        if (@c) {
            printf "Peak:           channel %d (%.1f keV), %d counts\n",
                $peak_ch, channel_to_keV($peak_ch, $a0, $a1, $a2), $peak;
        }
    }
    return 0;
}

# Alarm thresholds (read-only). Scaling follows cdump get_alarm_limits and was checked
# against the device: count = raw/10 (x60 for cpm); dose rate = raw/100 for Sv (uSv/h);
# accumulated dose = raw/1e6/100 for Sv. A raw value of 999999999 is the device's maximum.
sub read_alarms {
    my ($self) = @_;
    my @ids = (0x8008, 0x8009, 0x8013,    # CR_LEV1_cp10s, CR_LEV2_cp10s, CR_UNITS
               0x8000, 0x8001, 0x8004,    # DR_LEV1_uR_h,  DR_LEV2_uR_h,  DS_UNITS
               0x8014, 0x8015);           # DS_LEV1_uR,    DS_LEV2_uR
    my @r = $self->read_vsfrs_raw(@ids);
    return unless @r;
    my ($cr1, $cr2, $cr_u, $dr1, $dr2, $ds_u, $ds1, $ds2) = @r;

    my $cpm = (defined $cr_u && $cr_u) ? 1 : 0;
    my $sv  = (defined $ds_u && $ds_u) ? 1 : 0;
    my $dm  = $sv ? 100 : 1;
    my $max = 999999999;
    my $cm  = $cpm ? 60 : 1;

    my %a = (
        count_unit      => $cpm ? 'cpm' : 'cps',
        dose_unit       => $sv ? 'Sv' : 'R',
        dose_rate_unit  => $sv ? 'uSv/h' : 'uR/h',
        raw             => { cr1 => $cr1, cr2 => $cr2, dr1 => $dr1, dr2 => $dr2,
                             ds1 => $ds1, ds2 => $ds2 },
    );
    $a{count_level1}     = defined $cr1 ? $cr1 / 10 * $cm : undef;
    $a{count_level2}     = defined $cr2 ? $cr2 / 10 * $cm : undef;
    $a{dose_rate_level1} = defined $dr1 ? $dr1 / $dm : undef;
    $a{dose_rate_level2} = defined $dr2 ? $dr2 / $dm : undef;
    $a{dose_level1}      = defined $ds1 ? $ds1 / 1e6 / $dm : undef;
    $a{dose_level2}      = defined $ds2 ? $ds2 / 1e6 / $dm : undef;
    $a{dose_level1_at_max} = (defined $ds1 && $ds1 == $max) ? 1 : 0;
    $a{dose_level2_at_max} = (defined $ds2 && $ds2 == $max) ? 1 : 0;
    return \%a;
}

sub print_alarms {
    my ($self) = @_;
    my $a = $self->read_alarms();
    unless ($a) {
        print STDERR "ERROR: could not read alarm settings\n";
        return 1;
    }
    if ($self->{format} eq 'json') {
        print {$self->{out}} $self->{json}->encode($a), "\n";
        return 0;
    }
    my $cu = $a->{count_unit};
    my $du = $a->{dose_unit};
    my $ru = $a->{dose_rate_unit};
    printf "Count rate alarm 1:   %.2f %s (raw %s)\n", $a->{count_level1}, $cu, $a->{raw}{cr1};
    printf "Count rate alarm 2:   %.2f %s (raw %s)\n", $a->{count_level2}, $cu, $a->{raw}{cr2};
    printf "Dose rate alarm 1:    %.2f %s (raw %s)\n", $a->{dose_rate_level1}, $ru, $a->{raw}{dr1};
    printf "Dose rate alarm 2:    %.2f %s (raw %s)\n", $a->{dose_rate_level2}, $ru, $a->{raw}{dr2};
    printf "Dose alarm 1:         %.6g %s (raw %s%s)\n", $a->{dose_level1}, $du, $a->{raw}{ds1},
        $a->{dose_level1_at_max} ? ', device maximum' : '';
    printf "Dose alarm 2:         %.6g %s (raw %s%s)\n", $a->{dose_level2}, $du, $a->{raw}{ds2},
        $a->{dose_level2_at_max} ? ', device maximum' : '';
    return 0;
}

# Display, sound and language settings (read-only). Decoding follows cdump's setters:
#   display off-time: raw 3 = 30 s, otherwise (raw + 1) * 5 s
#   direction: 0 auto, 1 right, 2 left
#   language: register 0 = English on this device (device shows English). cdump documents
#             1 = en; the device can't be switched from here, so 0 = en is used as observed.
sub read_settings {
    my ($self) = @_;
    my @ids = (0x0511, 0x0512, 0x0513, 0x0515, 0x0516,   # BRT, CONTR, OFF_TIME, DIR, BACKLT_ON
               0x0521, 0x0522, 0x0531, 0x0502,           # SOUND_VOL, SOUND_ON, VIBRO_ON, LANG
               0x0520, 0x0530,                           # SOUND_CTRL, VIBRO_CTRL (per event)
               0x05E0);                                  # ALARM_MODE (0 continuous, 1 once)
    my @r = $self->read_vsfrs_raw(@ids);
    return unless @r;
    my ($brt, $contr, $off, $dir, $bl, $vol, $snd, $vib, $lang, $sctl, $vctl, $amode) = @r;
    my %s;
    $s{brightness}   = $brt   if defined $brt;
    $s{contrast}     = $contr if defined $contr;
    if (defined $off) {
        $s{display_off_s} = $off == 3 ? 30 : ($off + 1) * 5;
    }
    if (defined $dir) {
        # Menu names: 0 auto, 1 normal, 2 rotated (cdump calls 1 right and 2 left).
        $s{direction} = { 0 => 'auto', 1 => 'normal', 2 => 'rotated' }->{$dir} // "unknown($dir)";
    }
    $s{backlight_on} = $bl ? 1 : 0 if defined $bl;
    $s{sound_volume} = $vol if defined $vol;
    $s{sound_on}     = $snd ? 1 : 0 if defined $snd;
    $s{vibro_on}     = $vib ? 1 : 0 if defined $vib;
    $s{language}     = defined $lang ? ($lang ? 'ru' : 'en') : undef;   # observed mapping, see above
    if (defined $amode) {
        $s{alarm_mode} = { 0 => 'continuous', 1 => 'once' }->{$amode} // "unknown($amode)";
    }
    if (defined $sctl) {
        $s{sound_events}     = { map { $CTRL_NAME[$_] => (($sctl >> $_) & 1) ? 1 : 0 } 0 .. $#CTRL_NAME };
    }
    if (defined $vctl) {
        $s{vibration_events} = { map { $CTRL_NAME[$_] => (($vctl >> $_) & 1) ? 1 : 0 } 0 .. $#CTRL_NAME };
    }
    return \%s;
}

sub print_settings {
    my ($self) = @_;
    my $s = $self->read_settings();
    unless ($s) {
        print STDERR "ERROR: could not read settings\n";
        return 1;
    }
    if ($self->{format} eq 'json') {
        print {$self->{out}} $self->{json}->encode($s), "\n";
        return 0;
    }
    my @order = (
        [brightness      => 'Brightness',      sub { "$_[0] (0-9)" }],
        [contrast        => 'Contrast',        sub { $_[0] }],
        [display_off_s   => 'Display off after', sub { "$_[0] s" }],
        [direction       => 'Orientation',     sub { $_[0] }],
        [backlight_on    => 'Backlight',       sub { $_[0] ? 'on' : 'off' }],
        [sound_on        => 'Sound',           sub { $_[0] ? 'on' : 'off' }],
        [sound_volume    => 'Sound volume',    sub { $_[0] }],
        [vibro_on        => 'Vibration',       sub { $_[0] ? 'on' : 'off' }],
        [language        => 'Language',        sub { $_[0] }],
        [alarm_mode      => 'Alarm signal',    sub { $_[0] }],
    );
    for my $k (qw(sound_events vibration_events)) {
        next unless $s->{$k};
        my $label = $k eq 'sound_events' ? 'Sound per event' : 'Vibration per event';
        my @on = grep { $s->{$k}{$_} } @CTRL_NAME;
        printf "%-20s %s\n", "$label:", @on ? join(', ', @on) : '(none)';
    }
    for my $row (@order) {
        my ($k, $name, $fmt) = @$row;
        next unless exists $s->{$k};
        printf "%-20s %s\n", "$name:", $fmt->($s->{$k});
    }
    return 0;
}

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

# Phase 1: one snapshot of the status registers plus the latest RareData record.
sub read_status {
    my ($self) = @_;
    my %s;

    my $flags = $self->status_flags();
    $s{status_flags} = $flags if defined $flags;

    my @names = sort keys %STATUS_VSFR;
    my @raw = $self->read_vsfrs_raw(map { $STATUS_VSFR{$_}[0] } @names);
    for my $i (0 .. $#names) {
        next unless defined $raw[$i];          # register not exposed by this firmware
        my $tmpl = $STATUS_VSFR{$names[$i]}[1];
        $s{$names[$i]} = (unpack($tmpl, pack('V', $raw[$i])))[0];
    }

    # Count rate, dose rate, battery/charge and duration come from the buffered records.
    # The firmware does not expose CPS/DR/DS registers, so the latest realtime record
    # is the source for count and dose rate.
    my $raw_buf = $self->data_buf_raw();
    if (defined $raw_buf) {
        my @recs = decode_data_buf($raw_buf, $self->{base_time});
        # The buffer is not in time order, so pick the newest record by timestamp.
        my $newest = sub {
            my $type = shift;
            my ($r) = sort { $b->{time} <=> $a->{time} } grep { $_->{type} eq $type } @recs;
            return $r;
        };
        if (my $rt = $newest->('realtime')) {
            $s{rt_time}       = $rt->{time};
            $s{rt_count_rate} = $rt->{count_rate};
            $s{rt_count_cpm}  = $rt->{count_rate} * 60;
            $s{rt_dose_rate}  = $rt->{dose_rate};
            # Scale checked against the device display: raw 8.6e-06 shows 0.08 uSv/h,
            # i.e. uSv/h = raw * 1e4 (matches the 10000x factor in cdump's webserver example).
            $s{rt_dose_uSv_h} = $rt->{dose_rate} * 1e4;
        }
        # Rare records carry the device's measurement-duration counter, which only grows.
        # Timestamps can't be compared across sessions (the device counter resets at connect),
        # so the largest duration is the most recent record.
        my ($rare) = sort { $b->{duration} <=> $a->{duration} } grep { $_->{type} eq 'rare' } @recs;
        if ($rare) {
            $s{charge_level}    = $rare->{charge_level};
            $s{rare_temp_c}     = $rare->{temperature};
            $s{rare_duration_s} = $rare->{duration};
            $s{rare_dose}       = $rare->{dose};
            # Accumulated dose: raw * 1e4 = uSv (matches the device display: 0.0270 raw -> 270 uSv).
            $s{dose_uSv}        = $rare->{dose} * 1e4;
        }
        # The newest charge start/stop event shows whether the device was charging, even
        # when the buffer has no rare record (and so no charge level).
        my ($chg) = sort { $b->{time} <=> $a->{time} }
                    grep { $_->{type} eq 'event' && $_->{event_name} =~ /^CHARGE_(START|STOP)$/ } @recs;
        if ($chg) {
            $s{last_charge_event} = "$chg->{event_name} at " . iso_time($chg->{time});
        }
    }
    return \%s;
}

sub print_status {
    my ($self) = @_;
    my $s = $self->read_status();
    unless (keys %$s) {
        print STDERR "ERROR: could not read status registers\n";
        return 1;
    }

    if ($self->{format} eq 'json') {
        print {$self->{out}} $self->{json}->encode($s), "\n";
        return 0;
    }

    # Display order and labels. Units: rt_* values are the raw device scale from the
    # realtime record; register values follow the register names (uR = micro-R).
    my @order = (
        [rt_count_rate => 'Count rate',        sub { sprintf '%.2f cps', $_[0] }],
        [rt_count_cpm  => 'Count rate',        sub { sprintf '%.0f cpm', $_[0] }],
        [rt_dose_uSv_h => 'Dose rate',         sub { sprintf '%.3f uSv/h', $_[0] }],
        [rt_dose_rate  => 'Dose rate (raw)',   sub { sprintf '%.3g', $_[0] }],
        [dr_uR_h       => 'Dose rate',         sub { "$_[0] uR/h" }],
        [ds_uR         => 'Accumulated dose',  sub { "$_[0] uR" }],
        [temp_c        => 'Temperature',       sub { sprintf '%.1f C', $_[0] }],
        [charge_level  => 'Charge level',      sub { sprintf '%.1f %%', $_[0] }],
        [last_charge_event => 'Last charge event', sub { $_[0] }],
        [device_on     => 'Device on',         sub { $_[0] ? 'yes' : 'no' }],
        [status_flags  => 'Status flags',      sub { sprintf '0x%08X', $_[0] }],
        [rare_duration_s => 'Measure time',    sub { "$_[0] s" }],
        [rare_temp_c   => 'Temperature (rare)', sub { sprintf '%.1f C', $_[0] }],
        [dose_uSv      => 'Accumulated dose',  sub { sprintf '%.0f uSv', $_[0] }],
        [rare_dose     => 'Accumulated (raw)', sub { sprintf '%.4g', $_[0] }],
    );
    for my $row (@order) {
        my ($k, $name, $fmt) = @$row;
        next unless exists $s->{$k};
        printf "%-20s %s\n", "$name:", $fmt->($s->{$k});
    }
    # Charge level is only in rare records; say so instead of silently omitting it.
    printf "%-20s %s\n", 'Charge level:', 'not in device buffer (no reading yet)'
        unless exists $s->{charge_level};
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
        print {$self->{out}} "(no records)\n" if $self->{format} eq 'text';
        return 0;
    }
    $self->emit($_) for @recs;
    return 0;
}

# Poll the buffer and emit new records (duplicates across polls are dropped).
# count=0 means run until interrupted.
sub live {
    my ($self, $interval, $count) = @_;
    my $emitted = 0;
    while (1) {
        my $raw = $self->data_buf_raw();
        unless (defined $raw) {
            print STDERR "ERROR: could not read data buffer\n";
            return 1;
        }
        for my $r (decode_data_buf($raw, $self->{base_time})) {
            # Without --backfill, skip records dated before this session started (the device
            # buffer holds older history, including records with its own earlier clock).
            next if !$self->{backfill} && $r->{time} < $self->{start_time};
            next if $self->_seen($r);
            $self->emit($r);
            $emitted++;
            last if $count && $emitted >= $count;
        }
        last if $count && $emitted >= $count;
        select(undef, undef, undef, $interval);
    }
    return 0;
}

# Remember which records were already emitted. Keyed by type and millisecond timestamp.
sub _seen {
    my ($self, $r) = @_;
    my $key = $r->{type} . ':' . int($r->{time} * 100 + 0.5);
    return 1 if $self->{seen}{$key};
    if (keys %{$self->{seen}} >= SEEN_LIMIT) {
        $self->{seen} = {};
    }
    $self->{seen}{$key} = 1;
    return 0;
}

# Write one record in the selected format.
sub emit {
    my ($self, $r) = @_;
    my $fh = $self->{out};
    if ($self->{format} eq 'json') {
        my %h = %$r;
        $h{time} = iso_time($r->{time});
        print {$fh} $self->{json}->encode(\%h), "\n";
    } elsif ($self->{format} eq 'csv') {
        if ($self->{csv_header_due}) {
            print {$fh} join(',', @CSV_COLS), "\n";
            $self->{csv_header_due} = 0;
        }
        my %h = %$r;
        $h{time} = iso_time($r->{time});
        print {$fh} join(',', map { csv_field($h{$_}) } @CSV_COLS), "\n";
    } else {
        print {$fh} format_record($r), "\n";
    }
}

sub iso_time {
    my ($t) = @_;
    my $whole = int($t);
    my $ms = int(($t - $whole) * 1000);
    return sprintf('%s.%03d%s',
        strftime('%Y-%m-%dT%H:%M:%S', localtime($whole)),
        $ms,
        strftime('%z', localtime($whole)));
}

sub csv_field {
    my ($v) = @_;
    return '' unless defined $v;
    if ($v =~ /[,"\r\n]/) {
        (my $q = $v) =~ s/"/""/g;
        return qq("$q");
    }
    return $v;
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
    return "$ts  event     $r->{event_name} (id=$r->{event}) param=$r->{event_param1}" if $t eq 'event';
    return "$ts  $t";
}

# ============================================================================
# Long-running monitor (--monitor)
# ============================================================================

my %MONITOR_HEADER = (
    rates    => "time,cps,cpm,cps_err_pct,dose_rate_uSv_h,dose_rate_raw,flags\n",
    events   => "time,event_id,event_name,param1,flags\n",
    spectrogram => "time,a0,a1,a2," . join(',', map { "ch$_" } 0 .. 1023) . "\n",
);

# Append-mode file with a header written only when the file is new or empty.
sub _open_log {
    my ($file, $header) = @_;
    my $new = !(-s $file);
    open(my $fh, '>>', $file) or die "cannot open $file: $!\n";
    $fh->autoflush(1);
    print {$fh} $header if $new;
    return $fh;
}

# Open the log files for one local day: rates-DATE.csv, events-DATE.csv and, when
# spectrum logging is on, spectrogram-DATE.csv. Returns a hashref of filehandles.
sub _open_day {
    my ($dir, $day, $spec_on) = @_;
    my %fh = (
        rates  => _open_log("$dir/rates-$day.csv",  $MONITOR_HEADER{rates}),
        events => _open_log("$dir/events-$day.csv", $MONITOR_HEADER{events}),
    );
    $fh{spectrum} = _open_log("$dir/spectrogram-$day.csv", $MONITOR_HEADER{spectrogram}) if $spec_on;
    return \%fh;
}

sub _sleep {
    my ($seconds) = @_;
    select(undef, undef, undef, $seconds);
}

# Poll the device for a long time: realtime rates and alarm events go to CSV logs,
# and optionally the spectrum change over each interval. Survives link loss by
# reconnecting with backoff. SIGINT/SIGTERM stop it cleanly.
sub monitor {
    my ($self, %m) = @_;
    my $dir        = $m{dir} // './radiacode-data';
    my $interval   = $m{interval} // 2;
    my $spec_every = $m{spectrum_every} // 0;

    unless (-d $dir || mkdir($dir)) {
        print STDERR "ERROR: cannot create $dir: $!\n";
        return 1;
    }

    my $day = strftime('%Y-%m-%d', localtime);
    my %fh;
    eval {
        %fh = %{ _open_day($dir, $day, $spec_every) };
        1;
    } or do {
        print STDERR "ERROR: $@";
        return 1;
    };

    local $SIG{INT}  = sub { $RadiaCode::BLE::MONITOR_STOP = 1 };
    local $SIG{TERM} = sub { $RadiaCode::BLE::MONITOR_STOP = 1 };
    $MONITOR_STOP = 0;

    print STDERR "monitor: logging to $dir (Ctrl-C to stop)\n";
    my $backoff = 5;
    while (!$MONITOR_STOP) {
        unless ($self->open_session()) {
            print STDERR "monitor: not connected, retrying in ${backoff}s\n";
            _sleep($backoff);
            $backoff = $backoff * 2 > 300 ? 300 : $backoff * 2;
            next;
        }
        $backoff = 5;
        print STDERR "monitor: connected " . strftime('%Y-%m-%d %H:%M:%S', localtime) . "\n";

        my $session_start = time();
        $self->{start_time} = $session_start;
        $self->{seen}      = {};
        $self->{prev_spec} = undef;
        my $next_spec = $session_start;

        while (!$MONITOR_STOP) {
            my $today = strftime('%Y-%m-%d', localtime);
            if ($today ne $day) {
                close($_) for values %fh;
                eval { %fh = %{ _open_day($dir, $today, $spec_every) }; $day = $today; 1 }
                    or do { print STDERR "monitor: cannot open new log files: $@"; return 1 };
                print STDERR "monitor: new log files for $today\n";
            }
            my $raw = $self->data_buf_raw();
            last unless defined $raw;      # link lost or device not answering

            for my $r (decode_data_buf($raw, $self->{base_time})) {
                next if $r->{time} < $session_start;    # history from before this session
                next if $self->_seen($r);
                if ($r->{type} eq 'realtime') {
                    my $cps = $r->{count_rate};
                    printf {$fh{rates}} "%s,%.3f,%.1f,%.1f,%.6g,%.6g,%d\n",
                        iso_time($r->{time}), $cps, $cps * 60, $r->{count_rate_err},
                        $r->{dose_rate} * 1e4, $r->{dose_rate}, $r->{flags};
                } elsif ($r->{type} eq 'event') {
                    printf {$fh{events}} "%s,%d,%s,%d,%d\n",
                        iso_time($r->{time}), $r->{event}, $r->{event_name},
                        $r->{event_param1}, $r->{flags};
                }
            }

            if ($spec_every && time() >= $next_spec) {
                $self->spectrum_delta($fh{spectrum});
                $next_spec = time() + $spec_every;
            }
            _sleep($interval);
        }

        $self->ble_disconnect();
        print STDERR "monitor: link lost, reconnecting\n" if !$MONITOR_STOP;
    }

    close($_) for values %fh;
    $self->ble_disconnect();
    print STDERR "monitor: stopped\n";
    return 0;
}

# Read the cumulative spectrum and write the counts added since the previous read,
# as sparse rows (only channels that changed). A decrease means the device reset its
# spectrum; the new value becomes the baseline and nothing is written for that read.
sub spectrum_delta {
    my ($self, $fh) = @_;
    my $fmt = $self->{spec_fmt};
    unless (defined $fmt) {
        my $cfg = $self->configuration() // '';
        ($fmt) = $cfg =~ /^SpecFormatVersion\s*=\s*(\d+)/m;
        $fmt //= 0;
        $self->{spec_fmt} = $fmt;
    }
    my $raw = $self->read_vs(VS_SPECTRUM);
    unless (defined $raw) {
        print STDERR "monitor: spectrum read failed at " . strftime('%H:%M:%S', localtime) . "\n";
        return;
    }
    my $s = eval { decode_spectrum($raw, $fmt) };
    unless ($s) {
        print STDERR "monitor: spectrum decode failed: " . ($@ || 'malformed') . "\n";
        return;
    }

    my @c = @{ $s->{counts} };
    my $prev = $self->{prev_spec};
    $self->{prev_spec} = { duration => $s->{duration_s}, counts => \@c };
    return unless $prev;

    my $reset = $s->{duration_s} < $prev->{duration} || @c != @{ $prev->{counts} };
    for my $i (0 .. $#c) {
        last if $reset;
        $reset = 1 if $c[$i] < $prev->{counts}[$i];
    }
    if ($reset) {
        print STDERR "monitor: spectrum reset detected, new baseline\n";
        return;
    }

    my $now = iso_time(time());
    my ($a0, $a1, $a2) = @{$s}{qw(a0 a1 a2)};
    my @delta = map { $c[$_] - $prev->{counts}[$_] } 0 .. $#c;
    printf {$fh} "%s,%.9g,%.9g,%.9g,%s\n", $now, $a0, $a1, $a2, join(',', @delta);
}

sub debug {
    my ($self, $msg) = @_;
    print STDERR "  [DEBUG] $msg\n" if $self->{debug};
}

1;

# ============================================================================
# Plot (--plot): SVG graphs from the --monitor CSV logs. Reads files only, no device.
# ============================================================================

package RadiaCode::Plot;

use strict;
use warnings;
use Time::Local qw(timegm);



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

# The spectrogram has one row per time slice with 1024 channel columns. Turn it into one row
# per non-zero channel, which is what plot_spectrum() works from.
sub spectrogram_rows {
    my ($dir) = @_;
    my @out;
    for my $r (@{ read_logs($dir, 'spectrogram') }) {
        my ($a0, $a1, $a2) = @{$r}{qw(a0 a1 a2)};
        next unless defined $a0 && defined $a1 && defined $a2;
        for my $ch (0 .. 1023) {
            my $c = $r->{"ch$ch"} // 0;
            next unless $c > 0;
            push @out, { time => $r->{time}, channel => $ch,
                         energy_keV => $a0 + $a1 * $ch + $a2 * $ch * $ch, counts => $c };
        }
    }
    return \@out;
}

# All daily files of one kind, in date order: rates-*.csv (or a single rates.csv).
sub read_logs {
    my ($dir, $kind) = @_;
    my @rows;
    for my $file (sort glob("$dir/$kind*.csv")) {
        push @rows, @{ read_csv($file) };
    }
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

sub run {
    my ($dir) = @_;
    die "no such directory: $dir\n" unless -d $dir;
    my $rates  = read_logs($dir, 'rates');
    my $events = read_logs($dir, 'events');
    my $spec   = spectrogram_rows($dir);
    plot_rates($rates, $events, "$dir/rates.svg");
    plot_spectrum($spec, "$dir/spectrum.svg");
    return 0;
}

1;

# ============================================================================
# Main package helpers
# ============================================================================

package main;

# The POD below is the only manual. --help shows all of it as plain text; --man formats
# the same POD as a man page (pod2man, shown with man(1)). A bad command line shows only
# the SYNOPSIS and exits 1.
sub show_manual {
    require Pod::Usage;
    # -noperldoc: render the POD here, so it works without the perl-doc package (perldoc
    # would otherwise print the raw script when it is missing).
    Pod::Usage::pod2usage(-verbose => 2, -exitval => 0, -noperldoc => 1);
}

# --man: pod2man the POD and show it with man(1). Falls back to show_manual() when no
# working man(1) is found (a man that exits 0 without rendering a page is not trusted).
sub show_man {
    require Pod::Man;
    require File::Temp;
    my $roff = '';
    my $pm = Pod::Man->new(section => 1, center => 'RadiaCode tools', release => 'radiacode.pl',
                           name => 'RADIACODE');
    $pm->output_string(\$roff);
    $pm->parse_file($0);

    my (undef, $file) = File::Temp::tempfile(SUFFIX => '.1', UNLINK => 1);
    open my $fh, '>', $file or return show_manual();
    print {$fh} $roff;
    close $fh;

    return show_manual() unless grep { -x "$_/man" } split /:/, ($ENV{PATH} // '');

    # Check that man renders the page (look for the NAME heading) before using it.
    my $text = '';
    if (open my $man, '-|', 'man', '-l', $file) {
        local $/;
        $text = <$man> // '';
        close $man;
    }
    return show_manual() unless $text =~ /^NAME\s*$/m;

    if (-t STDOUT) {
        # Interactive: let man page through the terminal.
        system('man', '-l', $file);
    } else {
        print $text;
    }
    exit 0;
}

sub usage_error {
    require Pod::Usage;
    Pod::Usage::pod2usage(-verbose => 0, -exitval => 1, -output => \*STDERR);
}

# Run the CLI only when executed as a script, not when required (e.g. by t/).
run_cli() unless caller;
1;

__END__

=head1 NAME

radiacode.pl - read and log data from a RadiaCode radiation detector over Bluetooth LE

=head1 SYNOPSIS

  radiacode.pl -d AA:BB:CC:DD:EE:FF [action] [options]
  radiacode.pl --plot [DIR]
  radiacode.pl --man

 Options:
   -d, --device ADDR    BLE address of the device (required)
   -f, --format FMT     text, csv or json
   -o, --output FILE    append output to FILE
   -i, --interval SEC   live-mode poll interval
   -n, --count N        stop after N records
   --status, --spectrum, --monitor, --buffer, ...  actions (see ACTIONS)
   -h, --help           show this manual
   --man                show this manual

=head1 DESCRIPTION

B<radiacode.pl> talks to a RadiaCode radiation detector (RC-10x family) directly over
Bluetooth Low Energy, without the vendor app. It reads live count and dose rates, the
device status, the energy spectrum, the device configuration and settings, and the
records the device keeps in its buffer. It can also write settings back to the device,
and it can run as a long-running logger that writes CSV files per day.

The device must not be connected to another host (for example the phone app) at the
same time as this script.

The script needs Linux with BlueZ, because it opens L2CAP sockets directly. It uses
only core Perl modules, so there is nothing to install from CPAN.

Without an action, the script polls the device's buffered records and prints new ones
until you press Ctrl-C.

=head1 ACTIONS

With no action, live mode polls the device's buffered records and prints new ones.

=over 4

=item B<--info>

Show the serial number and firmware version.

=item B<--status>

Show the status registers: count rate (cps and cpm), dose rate (uSv/h), device
temperature, whether the device is on, status flags, the charge level, the last charge
start or stop event, and the accumulated dose. The charge level comes from the device's
"rare" records. If the buffer has none, the output says so instead of leaving the line out.

=item B<--spectrum>

Read the current energy spectrum. The summary lists the calibration in use. With
C<--format csv> or C<--format json> all 1024 channels are written, with the energy of
each channel.

=item B<--accum>

With C<--spectrum>, read the accumulated spectrum instead of the current one.

=item B<--spectrum-reset>

Clear the device's current spectrum. This writes to the device.

=item B<--energy-calib>

Read the energy calibration (a0, a1, a2) used for the keV labels of the spectrum.

=item B<--set-energy-calib> I<A0,A1,A2>

Write the energy calibration and read it back. This changes only the keV labels, not the
counts or the dose. It writes to the device.

=item B<--set> I<NAME=VALUE>

Write a device setting, read it back, and report it. This option can be repeated. It
writes to the device. The names are:

=over 4

=item brightness (0-9)

=item display-off (5, 10, 15 or 30 seconds)

=item direction (auto, normal or rotated)

=item backlight, sound, vibration (on or off)

=item alarm-count-1 and alarm-count-2 (count unit; count alarms take cps or cpm)

=item alarm-dose-rate-1 and alarm-dose-rate-2, alarm-dose-1 and alarm-dose-2 (uSv or uR,
following the device units)

=item alarm-mode (continuous or once)

=item sound-EVENT and vibration-EVENT (on or off), per alarm event, for example
C<vibration-dose-rate-off-scale=off>. Run C<--settings> to see the event names.

=back

=item B<--set-time> [I<T>]

Write the device clock. Use C<now> (the default) for the host clock, or
C<YYYY-MM-DD HH:MM:SS> in local time, which is sent as given. This writes to the device.

=item B<--alarms>

Show the count-rate, dose-rate and dose alarm thresholds. Read-only.

=item B<--settings>

Show the display, sound, vibration and language settings. Read-only.

=item B<--config>

Dump the device configuration as text.

=item B<--buffer>

Dump all records in the device buffer once, then exit.

=item B<--monitor>

Run as a long-running logger. Each local day gets its own files in the output directory:
C<rates-DATE.csv> for the rates, C<events-DATE.csv> for alarms and other device events,
and, with C<--spectrum-every>, C<spectrogram-DATE.csv>, which has one row per interval
with the counts added in each of the 1024 channels. The logger reconnects after a link
loss. Ctrl-C stops it. A spectrum reset is handled by the logger itself: it records the
reset and starts a new baseline.

=item B<--plot> [I<DIR>]

Draw C<DIR/rates.svg> and C<DIR/spectrum.svg> from the C<--monitor> logs. This needs no
device. I<DIR> defaults to C<--dir>, then C<./radiacode-data>.

=item B<--poweroff>

Power the device down. It can be woken with its button. This writes to the device.

=item B<--man>

Show this manual as a man page: the POD is formatted with C<pod2man> and shown with
C<man(1)>, paged in a terminal. If no working C<man> is found, it prints the same text
as C<--help>. It needs no device.

=item B<-h>, B<--help>

Show this manual as plain text, with all sections. It needs no device.

=back

=head1 OUTPUT OPTIONS

=over 4

=item B<-f>, B<--format> I<FMT>

C<text>, C<csv> or C<json>. The default is C<text>.

=item B<-o>, B<--output> I<FILE>

Append the output to I<FILE> instead of printing it. A CSV header is written only when
the file is empty or new.

=item B<--backfill>

In live mode, also output the records that were already in the device buffer at start.
By default only the records that arrive after start are output.

=back

=head1 OPTIONS

=over 4

=item B<-d>, B<--device> I<ADDR>

The Bluetooth address of the device. Required for every action except C<--plot> and C<--man>.

=item B<-i>, B<--interval> I<SEC>

Poll interval for live mode, in seconds. The default is 2.

=item B<-n>, B<--count> I<N>

Stop live mode after I<N> records. The default is to run until Ctrl-C.

=item B<--addr-type> I<TYPE>

C<public> or C<random>. The default is C<public>.

=item B<--connect-timeout> I<SEC>

Connect timeout in seconds. The default is 5.

=item B<--write-uuid> I<UUID>, B<--notify-uuid> I<UUID>

The GATT characteristics used for writing and for notifications. The defaults are the
ones the RadiaCode uses; you normally do not need to change them.

=item B<--dir> I<DIR>

Output directory for C<--monitor> and C<--plot>. The default is C<./radiacode-data>.

=item B<--spectrum-every> I<SEC>

With C<--monitor>, read the spectrum every I<SEC> seconds and log the change.

=item B<-v>, B<--debug>

Verbose protocol trace. Repeat for more detail.

=back

=head1 EXAMPLES

  # serial number and firmware
  radiacode.pl -d 52:43:06:E0:0C:23 --info

  # status, including the charge level if the buffer has it
  radiacode.pl -d 52:43:06:E0:0C:23 --status

  # ten readings, one every second, as CSV
  radiacode.pl -d 52:43:06:E0:0C:23 -i 1 -n 10 --format csv

  # save the current spectrum with all channels
  radiacode.pl -d 52:43:06:E0:0C:23 --spectrum --format csv \
      -o radiacode-data/spectrum-$(date +%Y%m%d-%H%M).csv

  # log to daily files, with a spectrogram every 5 minutes
  radiacode.pl -d 52:43:06:E0:0C:23 --monitor --spectrum-every 300

  # draw the SVG charts from the monitor logs (no device needed)
  radiacode.pl --plot

=head1 FILES

=over 4

=item F<radiacode-data/>

The default output directory for C<--monitor> and C<--plot>.

=back

=head1 NOTES

=over 4

=item *

Spectrum energies come from the device's calibration (a0 + a1*ch + a2*ch^2). The last
channel (1023) is an overflow bin for events above the full scale, so its counts are not
real energies. Do not fit a calibration to it.

=item *

The device's charge level is only in its "rare" buffer records, which are written every
few minutes. Realtime records carry a flags field, but it is not decoded to a charging
state.

=back

=head1 SEE ALSO

L<perlrun>, L<man(1)>

The protocol was worked out from the cdump project's RadiaCode code:
L<https://github.com/cdump/radiacode>.

=cut
