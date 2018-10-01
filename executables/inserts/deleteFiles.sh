#!/bin/sh
pwd
rm -fr ./executables/inserts/log*
mkdir -p ./executables/inserts/log{0..3}
touch ./executables/inserts/log{0..3}/access.log ./executables/inserts/log{0..3}/error.log
