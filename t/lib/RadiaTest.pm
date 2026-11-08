package RadiaTest;

# Test helpers: load radiacode.pl without running its CLI, and a fake device that speaks
# the RadiaCode framing over a socketpair (so the request/response code is exercised for real).

use strict;
use warnings;
use bytes;
use File::Basename qw(dirname);
use File::Spec;
use Socket qw(AF_UNIX SOCK_SEQPACKET PF_UNSPEC);
use Exporter 'import';

our @EXPORT_OK = qw(load_radiacode fake_device NOTIFY_HANDLE WRITE_HANDLE);

use constant {
    WRITE_HANDLE  => 0x000E,   # matches the handle layout used by the tests
    NOTIFY_HANDLE => 0x0010,
};

my $LOADED = 0;

sub load_radiacode {
    return if $LOADED++;
    my $root = File::Spec->catdir(dirname(__FILE__), '..', '..');
    my $script = File::Spec->catfile($root, 'radiacode.pl');
    # require runs the file; the CLI is guarded by `unless caller`, so nothing is executed.
    require $script;
}

# Run a fake device in a child process. $handler is called as
#   $handler->($cmd, $seq, $args) and must return the response body (bytes after the
# 4-byte header echo), or undef to send nothing.
# $client is called with a configured RadiaCode::BLE object and returns the test result.
sub fake_device {
    my ($handler, $client) = @_;
    socketpair(my $host, my $dev, AF_UNIX, SOCK_SEQPACKET, PF_UNSPEC)
        or die "socketpair: $!";
    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        close $host;
        _device_loop($dev, $handler);
        exit 0;
    }

    close $dev;
    my $d = RadiaCode::BLE->new(device => '00:00:00:00:00:00');
    $d->{socket}   = $host;
    $d->{h_write}  = WRITE_HANDLE;
    $d->{h_notify} = NOTIFY_HANDLE;
    my @result = $client->($d);
    close $host;
    waitpid($pid, 0);
    return @result;
}

sub _device_loop {
    my ($dev, $handler) = @_;
    while (1) {
        my $frame = _read_request($dev) or last;
        my $cmd = unpack('v', substr($frame, 4, 2));
        my $seq = ord(substr($frame, 7, 1));
        my $args = substr($frame, 8);
        my $body = $handler->($cmd, $seq, $args);
        next unless defined $body;
        my $hdr = substr($frame, 4, 4);
        my $stream = pack('V', length($hdr . $body)) . $hdr . $body;
        for (my $p = 0; $p < length $stream; $p += 20) {
            syswrite($dev, pack('C v', 0x1B, NOTIFY_HANDLE) . substr($stream, $p, 20));
        }
    }
}

# Collect ATT Write Commands until one complete [LEN][payload] frame has arrived.
sub _read_request {
    my ($dev) = @_;
    my $buf = '';
    my $want;
    while (1) {
        my $pdu = '';
        my $n = sysread($dev, $pdu, 512);
        return unless $n;
        die "unexpected ATT opcode\n" unless ord(substr($pdu, 0, 1)) == 0x52;
        $buf .= substr($pdu, 3);
        $want = unpack('V', substr($buf, 0, 4)) + 4 if !defined $want && length($buf) >= 4;
        return $buf if defined $want && length($buf) >= $want;
    }
}

1;
