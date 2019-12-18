#!/usr/bin/perl
#
# Copyright (c) 2019-2020, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2014, 2017 Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2010 Vyatta, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#

use strict;
use warnings;
use lib '/opt/vyatta/share/perl5/';

use Vyatta::Config;
use Vyatta::ConfigMgmt;
use Vyatta::Utils;
use Sort::Versions;
use Getopt::Long;
use File::Basename;
use File::Copy;
use URI;
use IO::Prompt;
use Sys::Syslog qw(:standard :macros);
use JSON;

my $commit_uri_script  = '/opt/vyatta/sbin/vyatta-commit-push.pl';
my $commit_revs_script = '/opt/vyatta/sbin/vyatta-commit-revs.pl';

my $commit_hook_dir            = cm_get_commit_hook_dir();
my $archive_dir                = cm_get_archive_dir();
my $config_file                = "$archive_dir/config.boot";
my $lr_conf_file               = cm_get_lr_conf_file();
my $config_dir                 = cm_get_config_dir();
my $confirm_job_file           = "$config_dir/confirm.job";
my $confirmed_commit_job_file  = "$config_dir/confirmed_commit.job";
my $confirmed_persist_job_file = "$config_dir/confirmed_persist.job";
my $revert_file                = "$archive_dir/config.boot.revert.gz";

my $debug = 0;

sub get_link {
    my ($path) = @_;

    my $script = basename($path);
    if ( $script =~ /revs/ ) {
        $script = "01" . $script;
    }
    elsif ( $script =~ /push/ ) {
        $script = "02" . $script;
    }
    my $link = $commit_hook_dir . $script;
    return $link;
}

sub check_integer {
    my ($num) = @_;

    if ( $num !~ /^\d+$/ ) {
        print "Invalid number [$num]\n";
        exit 1;
    }
    return 1;
}

sub check_valid_rev {
    my ($rev) = @_;

    check_integer($rev);
    my $num_revs = cm_get_num_revs();
    return 1 if $rev <= $num_revs;
    print "Invalid revision [$rev]\n";
    exit 1;
}

sub parse_at_output {
    my @lines = @_;
    foreach my $line (@lines) {
        if ( $line =~ /error/ ) {
            return ( 1, '', '' );
        }
        elsif ( $line =~ /job (\d+) (.*)$/ ) {
            return ( 0, $1, $2 );
        }
    }
    return ( 1, '', '' );
}

sub filter_file_lines {
    my ($diff) = @_;

    my @lines = split( "\n", $diff );
    my $line1 = shift @lines;
    my $line2 = shift @lines;
    unshift( @lines, $line2 ) if $line2 !~ /^\+\+\+ /;
    unshift( @lines, $line1 ) if $line1 !~ /^\-\-\- /;
    return join( "\n", @lines );
}

sub filter_version_string {
    my ($diff) = @_;

    # find last diff hunk, skip it if it's the version string
    my @lines     = split( "\n", $diff );
    my @last_hunk = ();
    my $found     = 0;
    while ( my $line = pop(@lines) ) {
        unshift( @last_hunk, $line );
        $found = 1 if $line =~ /vyatta-config-version/;
        last if $line =~ /^@@/;
    }
    return join( "\n", @lines ) if $found;
    push( @lines, @last_hunk );
    return join( "\n", @lines );
}

#
# main
#
my (
    $action,  $uri,       $revs,    $revnum,   $minutes, $seconds,
    $persist, $persistid, $session, $filename, $dest
);

Getopt::Long::Configure('pass_through');
GetOptions(
    "action=s"    => \$action,
    "uri=s"       => \$uri,
    "revs=s"      => \$revs,
    "revnum=s"    => \$revnum,
    "minutes=s"   => \$minutes,
    "file=s"      => \$filename,
    "dest=s"      => \$dest,
    "seconds=s"   => \$seconds,
    "persist=s"   => \$persist,
    "persistid=s" => \$persistid,
    "session=s"   => \$session,
);

die "Error: no action" if !defined $action;

my ( $cmd, $rc ) = ( '', 1 );

if ( $action eq 'update-uri' ) {
    print "update-uri\n" if $debug;

    # reference to a hash
    my $uris_ref = cm_get_commit_archive_uris();
    my $link     = get_link($commit_uri_script);
    print "update-uri: %$uris_ref, $link\n" if $debug;
    if ( %$uris_ref and !-e $link ) {
        print "add link [$link]\n" if $debug;
        $rc = system("ln -s $commit_uri_script $link");
        exit $rc;
    }
    elsif ( not %$uris_ref ) {
        $rc = 0;
        my $last_push_file = cm_get_last_push_file();
        if ( -e $last_push_file ) {
            print "unlink last_push_file [$last_push_file]\n" if $debug;
            unlink $last_push_file;
        }
        if ( -e $link ) {
            print "remove link [$link]\n" if $debug;
            $rc = system("rm -f $link");
        }
        exit $rc;
    }
    exit 0;
}

if ( $action eq 'valid-uri' ) {
    die "Error: no uri" if !defined $uri;
    print "valid-uri [$uri]\n" if $debug;
    my $u = URI->new($uri);
    exit 1 if !defined $u;
    my $scheme = $u->scheme();
    my $auth   = $u->authority();
    my $path   = $u->path();

    exit 1 if !defined $scheme or !defined $path;
    if ( $scheme eq 'tftp' ) {
    }
    elsif ( $scheme eq 'ftp' ) {
    }
    elsif ( $scheme eq 'scp' ) {
    }
    else {
        print "Unsupported URI scheme\n";
        exit 1;
    }
    exit 0;
}

if ( $action eq 'update-revs' ) {
    die "Error: no revs" if !defined $revs;
    print "update-revs [$revs]\n" if $debug;
    check_integer($revs);
    my $link = get_link($commit_revs_script);
    if ( $revs == 0 ) {
        print "remove link [$link]\n" if $debug;
        $rc = system("rm -f $link");
    }
    else {
        if ( !-e $link ) {
            print "add link [$link]\n" if $debug;
            $rc = system("ln -s $commit_revs_script $link");
        }
        if ( !-e $archive_dir ) {
            system("mkdir $archive_dir");
            system("chgrp vyattacfg $archive_dir");
            system("chmod 775 $archive_dir");
        }

        my $lr_version =
          parse_version_string(`/usr/sbin/logrotate 2>&1 | head -1`);
        my $lr_su_root_conf = '';

        # since 3.8.0 logrotate ignores group writable directories not owned
        # by the 'root' group if the 'su' option is not configured
        if ( versioncmp( '3.8.0', $lr_version ) < 1 ) {
            $lr_su_root_conf = 'su root vyattacfg';
        }

        my $lr_conf = <<END;
$config_file {
	rotate $revs
	start 0
	compress
	copy
	$lr_su_root_conf
}
END
        cm_write_file( $lr_conf_file, $lr_conf );
        system("chmod 640 $lr_conf_file");
        my $num_revs = cm_get_num_revs();
        if ( !-e "$archive_dir/commits" or $num_revs == 0 ) {

            # store a baseline config
            system("touch $archive_dir/commits");
            system("chgrp vyattacfg $archive_dir/commits");
            system("chmod 664 $archive_dir/commits");
            my $cmd = "$commit_revs_script baseline config.boot";
            system("sg vyattacfg \"export COMMIT_VIA=init; $cmd\"");
        }
        exit 0;
    }
    exit 0;
}

if ( $action eq 'show-commit-log' ) {
    print "show-commit-log\n" if $debug;
    my $max_revs = cm_get_max_revs();
    if ( !defined $max_revs or $max_revs <= 0 ) {
        print "commit-revisions is not configured.\n\n";
    }
    my @log = cm_commit_get_log();
    foreach my $line (@log) {
        print $line;
    }
    exit 0;
}

if ( $action eq 'show-commit-log-brief' ) {
    print "show-commit-log-brief\n" if $debug;
    my $max_revs = cm_get_max_revs();
    my @log      = cm_commit_get_log(1);
    foreach my $line (@log) {
        $line =~ s/\s/_/g;
        print $line, ' ';
    }
    exit 0;
}

if ( $action eq 'show-commit-file' ) {
    die "Error: no revnum" if !defined $revnum;
    print "show-commit-file [$revnum]\n" if $debug;
    check_valid_rev($revnum);
    my $file = cm_commit_get_file($revnum);
    print $file;
    exit 0;
}

if ( $action eq 'diff' ) {
    print "diff\n" if $debug;
    my $args = $#ARGV;
    if ( $args < 0 ) {
        my $rc = system("cli-shell-api sessionChanged");
        if ( defined $rc and $rc > 0 ) {
            print "No changes between working and active configurations\n";
            exit 0;
        }
        my $show_args = '--show-show-defaults --show-context-diff';

        # default behavior for showConfig is @ACTIVE vs. @WORKING, so no
        # need to write to a file first
        my $diff =
`bash -c "cfgdiff -ctxdiff <(cli-shell-api showConfig) <(cli-shell-api showCfg --show-active-only)"`;
        if ( defined $diff and length($diff) > 0 ) {
            print "$diff";
        }
        else {
            print "No changes between working and active configurations\n";
            exit 0;
        }
    }
    elsif ( $args eq 0 ) {
        my $rev1 = $ARGV[0];
        check_valid_rev($rev1);
        my $filename1 = cm_commit_get_file_name($rev1);
        my $outfile   = $filename1;
        $outfile =~ s/(.*)\.gz/$1/g;
        my $diff =
`bash -c "cfgdiff -ctxdiff <(cli-shell-api showConfig) <(cfgread $filename1)"`;
        if ( defined $diff and length($diff) > 0 ) {
            print "$diff";
        }
        else {
            print "No changes between working and "
              . "revision $rev1 configurations\n";
        }
    }
    elsif ( $args eq 1 ) {
        my $rev1 = $ARGV[0];
        my $rev2 = $ARGV[1];
        check_valid_rev($rev1);
        check_valid_rev($rev2);
        my $filename  = cm_commit_get_file_name($rev1);
        my $filename2 = cm_commit_get_file_name($rev2);
        my $diff =
`bash -c "cfgdiff -ctxdiff <(cfgread $filename) <(cfgread $filename2)"`;
        if ( defined $diff and length($diff) > 0 ) {
            print "$diff";
        }
        else {
            print "No changes between revision $rev1 and "
              . "revision $rev2 configurations\n";
        }
    }
    elsif ( $args eq 2 ) {
        my $rev1 = $ARGV[0];
        my $rev2 = $ARGV[1];
        check_valid_rev($rev1);
        check_valid_rev($rev2);
        my $filename  = cm_commit_get_file_name($rev1);
        my $filename2 = cm_commit_get_file_name($rev2);
        my $diff =
`bash -c "cfgdiff -ctxdiff <(cfgread $filename) <(cfgread $filename2)"`;
        if ( defined $diff and length($diff) > 0 ) {
            my @difflines = split( '\n', $diff );
            foreach my $line (@difflines) {
                my @words    = split( ' ', $line );
                my $elements = scalar(@words);
                my @non_leaf = @words[ 0 .. ( $elements - 2 ) ];
                my $path     = join( ' ', @non_leaf );
                $path =~ s/'//g;
                my $cmd = "$path " . @words[ ( $elements - 1 ) ];
                print "$cmd\n";
            }
        }
        else {
            print "No changes between revision $rev1 and "
              . "revision $rev2 configurations\n";
        }
    }
    exit 0;
}

if ( $action eq 'commit-confirm' ) {
    die "Error: no minutes" if !defined $minutes;
    print "commit-confirm [$minutes]\n" if $debug;

    # commit-confirm silently confirms any previous pending commit-confirm
    remove_confirm_job_file();

    my $max_revs = cm_get_max_revs();
    if ( !defined $max_revs or $max_revs <= 0 ) {
        print "commit-revisions is not configured.\n\n";
        exit 1;
    }

    check_integer($minutes);
    print "commit will rollback to previous version in $minutes"
      . " minutes unless you enter 'confirm'\n";

    # To get rollback triggered at whole minute intervals, we need to add
    # a sleep in front of the command for the number of seconds into the
    # current minute at which we queue the command.
    my $sleep_time = substr `date +'%S'`, 0, 2;

    # Always rollback to immediately preceding config version.
    $cmd = "/opt/vyatta/sbin/revert_to_previous_config.sh";

    # Need to run with correct permissions.  This is the same as we use
    # in configd.service to start configd, using 'lu'.
    my @lines =
`echo "sleep $sleep_time && /opt/vyatta/sbin/lu -user configd \\"$cmd\\"" | at now + $minutes minutes 2>&1`;
    my ( $err, $job, $time ) = parse_at_output(@lines);
    if ($err) {
        print "Error: unable to schedule rollback\n";
        exit 1;
    }
    system("echo $job > $confirm_job_file");
    exit 0;
}

if ( $action eq 'revert-configuration' ) {
    remove_confirm_job_file();
    remove_confirmed_commit_job_file();

    my $cmd = "/opt/vyatta/sbin/revert_confirmed_commit.sh";
    my @lines =
      `echo "/opt/vyatta/sbin/lu -user configd \\"$cmd\\"" | at now 2>&1`;
    my ( $err, $job, $time ) = parse_at_output(@lines);
    if ($err) {
        print "Error: unable to schedule rollback\n";
        exit 1;
    }
    exit 0;
}

if ( $action eq 'confirmed-commit' ) {
    die "Error: no timeout" if ( !defined $seconds );
    print "confirmed-commit [$seconds]\n" if $debug;
    print "confirmed-commit [$seconds]\n";

    # confirmed-commit silently confirms any previous pending commit-confirm
    remove_confirm_job_file();
    remove_confirmed_commit_job_file();

    my $max_revs = cm_get_max_revs();
    if ( !defined $max_revs or $max_revs <= 0 ) {
        print "commit-revisions is not configured.\n\n";
        exit 1;
    }

    check_integer($seconds);
    print "confirmed commit will be reverted in $seconds"
      . " seconds unless there is a confirming commit\n";

    # Always rollback to immediately preceding config version.
    $cmd = "/opt/vyatta/sbin/revert_confirmed_commit.sh";

    # at only supports times on minute boundaries
    # adjust timeout to ensure at least the required time is scheduled
    # even if this means up to an extra 59 seconds is included
    my $sleep_time = substr `date +'%S'`, 0, 2;
    my $mins = $seconds + $sleep_time + 60;
    $mins = int( $mins / 60 );

    # Need to run with correct permissions.  This is the same as we use
    # in configd.service to start configd, using 'lu'.
    my @lines =
`echo "/opt/vyatta/sbin/lu -user configd \\"$cmd\\"" | at now + $mins minutes 2>&1`;
    my ( $err, $job, $time ) = parse_at_output(@lines);
    if ($err) {
        print "Error: unable to schedule rollback\n";
        exit 1;
    }

    my %confirmedinfo;
    $confirmedinfo{"job"}     = $job;
    $confirmedinfo{"session"} = $session;
    $confirmedinfo{"time"} = $time;
    if ( defined $persist ) {
        $confirmedinfo{"persist-id"} = $persist;
    }
    my $output = encode_json \%confirmedinfo;
    system("echo '$output' > $confirmed_commit_job_file");

    # if a revert file already exists, must be a follow-up
    # confirmed-commit, leave in place to ensure config revert
    # reverts back to initial confirmed commit
    if ( !-e $revert_file ) {
        system("cp $archive_dir/config.boot.1.gz $revert_file");
    }
    exit 0;
}

if ( $action eq 'show-confirmed-commit' ) {
    my %results;
    if ( !-e $confirmed_commit_job_file ) {
        print "{}";
        exit 0;
    }
    my $fl  = `cat $confirmed_commit_job_file`;
    my %cmt = %{ decode_json($fl) };

    $results{'session'}    = $cmt{'session'};
    $results{'persist-id'} = $cmt{'persist-id'}
      if ( defined $cmt{'persist-id'} );
    print encode_json \%results;
    exit 0;
}

if ( $action eq 'confirm' ) {
    if ( defined $persistid and $persistid ne "" ) {
        if ( !-e $confirmed_commit_job_file ) {
            print "No confirmed commit pending\n";
            exit 0;
        }
        my $fl  = `cat $confirmed_commit_job_file`;
        my %cmt = %{ decode_json($fl) };
        if ( !defined $cmt{"persist-id"} or $persistid ne $cmt{"persist-id"} ) {
            print "persist-id does not match pending confirmed commit\n";
            exit 0;
        }
        if ( -e $revert_file ) {
            system("rm -f $revert_file");
        }
        remove_confirmed_commit_job_file();
    }
    else {
        if ( !-e $confirm_job_file ) {
            print "No confirm pending\n";
            exit 0;
        }

        remove_confirm_job_file();
    }
    exit 0;
}

if ( $action eq 'confirming-commit' ) {
    if ( -e $revert_file ) {
        system("rm -f $revert_file");
    }
    remove_confirmed_commit_job_file();
    exit 0;
}

# Not an advertised command.
#
# Used to ensure that if we run 'commit' after 'commit-confirm' that we cancel
# the pending rollback without the 'no commit pending' message being printed
# as that will only serve to confuse users.
#
if ( $action eq 'confirm-silent' ) {
    remove_confirm_job_file();
    exit 0;
}

sub remove_confirm_job_file {
    if ( !-e $confirm_job_file ) {
        return;
    }
    my $job = `cat $confirm_job_file`;
    chomp $job;
    system("atrm $job 2> /dev/null");   # Silence 'deleting running job' warning
                                        # which we will get once sleep kicks in.
    system("rm -f $confirm_job_file");
}

sub remove_confirmed_commit_job_file {
    if ( !-e $confirmed_commit_job_file ) {
        return;
    }
    my $fl  = `cat $confirmed_commit_job_file`;
    my %cmt = %{ decode_json($fl) };

    system("atrm $cmt{'job'} 2> /dev/null");
    system("rm -f $confirmed_commit_job_file");
}

if ( $action eq 'extract-archive' ) {
    my ( $method, $extract_config ) = ( undef, undef );

    if ( !defined($revnum) || !defined($dest) ) {
        die "Error: must define revnum and destination";
    }

    check_valid_rev($revnum);
    $extract_config = cm_commit_get_file_raw($revnum);

    cm_write_file( $dest, $extract_config );
    exit 0;
}

if ( $action eq 'rollback' ) {
    my ( $method, $rollback_config ) = ( undef, undef );

    if ( defined $revnum ) {
        print "rollback [$revnum]\n" if $debug;
        check_valid_rev($revnum);
        $method = 'revnum';
        if ( prompt( "Proceed with reboot? [confirm]", -y1d => "y" ) ) {
        }
        else {
            print "Cancelling rollback\n";
            exit 0;
        }
        $rollback_config = cm_commit_get_file($revnum);
    }

    if ( defined $filename ) {
        print "rollback [$filename]\n" if $debug;
        if ( !-e $filename ) {
            die "Error: file [$filename] doesn't exist";
        }
        if ( defined $method ) {
            die "Error: can only define revnum or file";
        }
        $method = 'file';

        # Should have code to validate config, but for now only
        # called internally.  If we later expose this to cli
        # we'll need to prompt for confirmation.
        my @lines = cm_read_file($filename);
        $rollback_config = join( "\n", @lines );
        $rollback_config .= "\n";
    }
    if ( !defined $method ) {
        die "Error: must define either revnum or file";
    }

    my ($user)           = getpwuid($<);
    my $boot_config_file = cm_get_boot_config_file();
    my $archive_dir      = cm_get_archive_dir();
    my $last_commit_file = cm_get_last_commit_file();
    system("cp $boot_config_file $archive_dir/config.boot-prerollback");
    cm_write_file( $boot_config_file, $rollback_config );
    cm_write_file( $last_commit_file, $rollback_config );    # white lie
    my $cmd = "$commit_revs_script --rollback=1 rollback/reboot";
    system("sg vyattacfg \"$cmd\"");
    openlog( $0, "", LOG_USER );
    my $login = getpwuid($<) || "unknown";
    syslog( "warning", "Rollback reboot requested by $login" );
    closelog();
    exec("/sbin/reboot");
}

exit $rc;

# end of file
