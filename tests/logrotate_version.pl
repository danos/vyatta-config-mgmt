#!/usr/bin/perl -w -I ../lib -I ../scripts
#
# Copyright (c) 2019, AT&T Intellectual Property. All rights reserved.
#
# Copyright (c) 2014, Brocade Communications Systems, Inc.
# All Rights Reserved.
#
# SPDX-License-Identifier: GPL-2.0-only
#

use strict;
use warnings 'all';
use Test::More 'no_plan';  # or use Test::More 'no_plan';

use_ok('Vyatta::Utils');

is(parse_version_string("Hello 1 World"), "");
is(parse_version_string("Hello 1.2 World"), "1.2");
is(parse_version_string("Hello 1.2.3 World"), "1.2.3");
is(parse_version_string("Hello 1.2.3-1 World"), "1.2.3-1");
is(parse_version_string("Hello 1.2.3.4 World"), "1.2.3.4");

use_ok('Sort::Versions');

is(versioncmp('3.8.0','3.7.9'), 1);
is(versioncmp('3.8.0','3.8.0'), 0);
is(versioncmp('3.8.0','3.8.0+vyatta'), -1);
is(versioncmp('3.8.0','3.8.1'), -1);
