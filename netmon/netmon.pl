#!/usr/bin/env perl
# capture network performance and send to influx
#
# specify options either /etc/defaults/netmon and/or command-line

use Time::Local;
use POSIX;
use strict;

# format for date/time in the log messages
my $DATE_FORMAT = "%Y.%m.%d %H:%M:%S";

my $curl = '/usr/local/bin/curl';
my $speedtest = '/usr/local/bin/speedtest';
my $influx_host = '192.168.1.1';
my $influx_port = 8086;
my $influx_db = 'net';
my $influx_srv = q();

my $version = '0.3';
my $verbose = 0;
my $doit = 1;
my $iface_list = q();

# get values from defaults file, if one exists
if (open(IFILE, "</etc/defaults/netmon.conf")) {
    while(<IFILE>) {
        my $line = $_;
        if ($line =~ /^INTERFACE_LIST\s*=\s*(\S+)/) {
            $iface_list = $1;
        } elsif ($line =~ /^INFLUX_HOST\s*=\s*(\S+)/) {
            $influx_host = $1;
        } elsif ($line =~ /^INFLUX_PORT\s*=\s*(\S+)/) {
            $influx_port = $1;
        } elsif ($line =~ /^INFLUX_DB\s*=\s*(\S+)/) {
            $influx_db = $1;
        } elsif ($line =~ /^INFLUX_SRV\s*=\s*(\S+)/) {
            $influx_srv = $1;
        }
    }
    close(IFILE);
}

# override with any command-line options
while($ARGV[0]) {
    my $arg = shift;
    if ($arg eq '--version') {
        print "$version\n";
    } elsif ($arg eq '--debug') {
        $doit = 0;
    } elsif ($arg eq '--verbose') {
        $verbose = 1;
    } elsif ($arg eq '--iface-list') {
        $iface_list = shift;
    } elsif ($arg eq '--influx-host') {
        $influx_host = shift;
    } elsif ($arg eq '--influx-port') {
        $influx_port = shift;
    } elsif ($arg eq '--influx-db') {
        $influx_db = shift;
    } elsif ($arg eq '--influx-srv') {
        $influx_srv = shift;
    } elsif ($arg eq '--help') {
        print "options include:\n";
        print "  --verbose\n";
        print "  --iface-list   comma-delimited list of IP addresses\n";
        print "  --influx-host  host name/address of influx server\n";
        print "  --influx-port  port number of influx server\n";
        print "  --influx-db    database name\n";
        print "  --influx-srv   full influx server url\n";
        print "\n";
        print "these can also be specified in /etc/defaults/netmon\n";
        exit 0;
    }
}

if ($influx_srv eq q()) {
    $influx_srv = "http://${influx_host}:${influx_port}"
}

my $influx_url = "${influx_srv}/write?db=${influx_db}";

$iface_list = 'default' if $iface_list eq q();
logmsg("check network performance: interfaces=$iface_list");
logmsg("influx_url=$influx_url") if $verbose;
my @ifaces = split(',', $iface_list);
foreach my $iface (@ifaces) {
    my $cmd = "$speedtest --csv";
    if ($iface ne 'default') {
        $cmd .= " --source $iface";
    }
    logmsg("get data for interface '$iface'");
    my @output = `$cmd`;
    foreach my $line (@output) {
        $line =~ s/\s+$//g;
        logmsg("values=$line") if $verbose;
        my @values = parse_csv($line);
        send_data($iface, @values);
    }
}

exit 0;


# parse a line of comma-separated values
# https://www.oreilly.com/library/view/perl-cookbook/1565922433/ch01s16.html
# FIXME: would prefer to use CPAN here, but minimal dependencies
sub parse_csv {
    my $text = shift;      # record containing comma-separated values
    my @new  = ();
        push(@new, $+) while $text =~ m{
        # the first part groups the phrase inside the quotes.
        # see explanation of this pattern in MRE
        "([^\"\\]*(?:\\.[^\"\\]*)*)",?
           |  ([^,]+),?
           | ,
       }gx;
    push(@new, undef) if substr($text, -1,1) eq ',';
    return @new;      # list of values that were comma-separated
}

# given list of values, send to influx server.  the list of values should be:
#
#  Server ID,Sponsor,Server Name,Timestamp,Distance,Ping,Download,Upload,Share,IP Address

sub send_data {
    my ($iface,@values) = @_;
    my $tstr = $values[3]; # 2021-07-05T13:19:22.240696Z
    my $distance = $values[4];
    my $ping = $values[5]; # ms
    my $dn = $values[6]; # bits/s
    my $up = $values[7]; # bits/s
    my $addr = $values[9]; # client ip address
    my $ts = 0;
    if ($tstr =~ /^(\d{1,4})\-(\d{1,2})\-(\d{1,2})T(\d{1,2}):(\d{1,2}):(.*)Z$/) {
        my $sec = $6;
        my $min = $5;
        my $hour = $4;
        my $mday = $3;
        my $mon = $2;
        my $year = $1;
        $hour |= 0;
        $min |= 0;
        $mon -= 1;
        $year = $year < 100 ? ($year < 70 ? 2000+$year : 1900+$year) : $year;
        logmsg("y=$year m=$mon d=$mday H:M:S=$hour:$min:$sec") if $verbose;
        $ts = timegm(0, $min, $hour, $mday, $mon, $year);
        logmsg("ts=$ts") if $verbose;
        # influx wants nanoseconds
        $ts *= 1_000_000_000;
        logmsg("ts=$ts") if $verbose;
    }
    my @fields = ("dn=$dn", "up=$up", "ping=$ping", "distance=$distance");
    my $payload = q();
    foreach my $field (@fields) {
        $payload .= "uplink,iface=$iface,addr=$addr $field $ts\n";
    }
    my $cmd = "$curl -s -i -XPOST '$influx_url' --data-binary '$payload'";
    logmsg("$cmd") if $verbose;
    `$cmd` if $doit;
}

sub logmsg {
    my ($message) = @_;
    my $tstr = strftime $DATE_FORMAT, localtime time;
    print "$tstr $message\n";
}
