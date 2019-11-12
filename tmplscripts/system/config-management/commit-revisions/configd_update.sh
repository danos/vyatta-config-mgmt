#!/opt/vyatta/bin/cliexec
${vyatta_sbindir}/vyatta-config-mgmt.pl \
    --action=update-revs                \
    --revs="$VAR(@)"
