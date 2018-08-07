#!/bin/sh
pwd
rm -fr ./executables/bolosim/log*
mkdir -p ./executables/bolosim/log{0..3}
touch ./executables/bolosim/log{0..3}/access.log ./executables/bolosim/log{0..3}/error.log
