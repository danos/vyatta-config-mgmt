#!/usr/bin/perl
#
# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
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
use File::Compare;
use Getopt::Long;

#
# main
#

my $rollback;
my $grub;
my $unconf;
Getopt::Long::Configure('pass_through');
GetOptions(
    "rollback=s"    => \$rollback,
    "grub"          => \$grub,
    "unconf_reboot" => \$unconf,
);

my $archive_dir      = cm_get_archive_dir();
my $lr_state_file    = cm_get_lr_state_file();
my $lr_conf_file     = cm_get_lr_conf_file();
my $last_commit_file = cm_get_last_commit_file();
my $tmp_config_file  = "/tmp/config.boot.$$";

my $commit_status = $ENV{'COMMIT_STATUS'};
my $commit_via    = $ENV{'COMMIT_VIA'};
my $commit_cmt    = $ENV{'COMMIT_COMMENT'};
$commit_status = 'unknown' if !defined $commit_status;
$commit_via    = 'other'   if !defined $commit_via;
$commit_cmt    = 'commit'  if !defined $commit_cmt;

if ( !-d $archive_dir ) {
    system("mkdir $archive_dir");
    system("chown vyatta:vyattacfg $archive_dir");
}
if ( ( defined $rollback ) || ( defined $grub ) || ( defined $unconf ) ) {

    # This could be normal rollback, GRUB config recovery, or rollback
    # after a reboot within the commit-confirm confirmation period.

    # We know we have a new configuration so unconditionally copy into
    # archive directory ready for archiving.
    my $boot_config_file = cm_get_boot_config_file();
    system("cp $boot_config_file $archive_dir/config.boot");
}
else {
    # Get committed configuration and compare to most recently saved config
    # (archive/config.boot (and archive/config.boot.0.gz)):
    #   - if same, nothing to do
    #   - if different, replace archive/config.boot and continue to
    #     logrotate operation.
    my $cmd = '/opt/vyatta/sbin/vyatta-save-config.pl';
    system("$cmd $tmp_config_file --no-defaults > /dev/null");
    if ( compare( $tmp_config_file, $last_commit_file ) == 0 ) {
        exit 0;
    }
    system("mv $tmp_config_file $archive_dir/config.boot");
}

system("logrotate -f -s $lr_state_file $lr_conf_file");
my $user = $ENV{'COMMIT_USER'} || getlogin() || getpwuid($>) || "unknown";
cm_commit_add_log( $user, $commit_via, $commit_cmt );

exit 0;

# end of file
