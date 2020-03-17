#!/bin/vcli -f
configure
cfgcli cancel-commit force comment "Reverted confirmed commit"
end_configure
