#!/bin/bash

rlwrap -A bin/osx/kadenaclient -c "conf/$(ls conf | grep -m 1 client)" +RTS -N2
