#!/bin/bash

stack exec -- rlwrap -A kadenaclient -c "conf/$(ls conf | grep -m 1 client)" +RTS -N2
