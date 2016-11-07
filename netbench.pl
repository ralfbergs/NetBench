#!/usr/bin/env perl
use warnings;
use strict;
use Config;
use Time::HiRes qw ( time );
use LockFile::Simple qw(unlock trylock);
use File::Basename;
use LWP::Simple;
use threads ('yield',
	     'stack_size' => 64*4096,
	     'exit' => 'threads_only',
	     'stringify');
use LWP::UserAgent;
use RRDs;


use constant DEBUG => 0;

# URL which will return the current "RX bytes" and "TX bytes" counters on WAN interface
use constant RX_BYTES_URL => "http://gw.gv.internal.bergs.biz/cgi-bin/get-rx-bytes.sh";
use constant TX_BYTES_URL => "http://gw.gv.internal.bergs.biz/cgi-bin/get-tx-bytes.sh";

use constant URL_DN => "http://speedcheck.vodafone.de/speedtest/random4000x4000.jpg";
use constant URL_UP => "http://speedcheck.vodafone.de/speedtest/upload.php";

use constant RRD_FILENAME => "/var/lib/rrd/netbench/netbench.rrd";


# Function prototypes
sub main();
sub rnd_str(@);

main();

sub do_download() {
    my $before = time();

    system("/usr/bin/siege --log=/dev/null -c 10 -b -t20s " . URL_DN . ">/dev/null 2>&1");

    my $after = time();

    my $time_dn = $after - $before;
    return($time_dn);
}

sub do_upload() {
    my $payload = rnd_str 3000000, 'A'..'Z';

    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);

    my $b4 = time();

    system("/usr/bin/siege --log=/dev/null -c 6 -b -t20s \"" . URL_UP . " POST </root/binfile3m.bin\" >/dev/null 2>&1");

    my $aftr = time();

    return($aftr - $b4);
}

# Generate random string of specified length from specified set of characters
# Usage: print rnd_str 8, 'a'..'z', 0..9;
sub rnd_str(@) {
    join'', @_[ map{ rand @_ } 1 .. shift ]
}

sub main() {
    my $LOCKFILE_DIR = "/run/lock/";
    if ("$Config{osname}" eq "darwin") {
	$LOCKFILE_DIR = "/var/tmp/";
    }


    my $LOCKFILE = basename($0, ".pl");
    $LOCKFILE = $LOCKFILE_DIR . $LOCKFILE;
    die "Cannot obtain lock ${LOCKFILE}.lock, already locked.\n" unless trylock($LOCKFILE);

    my $in_octets_1 = get(RX_BYTES_URL);
    my $time_dn = do_download();
    my $in_octets_2 = get(RX_BYTES_URL);

    if (DEBUG) {
	printf "Total octets downloaded: %d = %.1f MByte\n", $in_octets_2 - $in_octets_1,
		  ($in_octets_2 - $in_octets_1) / 1024**2;
	printf "Download took %.2f sec\n", $time_dn;
    }

    my $out_octets_1 = get(TX_BYTES_URL);
    my $time_up = do_upload();
    my $out_octets_2 = get(TX_BYTES_URL);

    if (DEBUG) {
	printf "Total octets uploaded: %d = %.1f MByte\n", $out_octets_2 - $out_octets_1,
		  ($out_octets_2 - $out_octets_1) / 1024**2;
	printf "Upload took %.2f sec\n", $time_up;
    }

    my $down = ($in_octets_2 - $in_octets_1) / $time_dn / 1024**2 * 8;
    my $up = ($out_octets_2 - $out_octets_1) / $time_up / 1024**2 * 8;
    my $now = time();
    printf "%d\t%.2f\t%.2f\n", $now, $down, $up;

    my $values = sprintf("%d:%.2f:%.2f", $now, $down, $up);
    RRDs::updatev (RRD_FILENAME, "--template", "down:up", $values);
    my $err = RRDs::error;
    if ($err) {
	warn "ERROR while updating ", RRD_FILENAME, ": ", $err;
    }

    unlock($LOCKFILE);
    exit(0);

}
