#!/bin/sh
pwd
rm -fr ./test-files/log*
mkdir -p ./test-files/log{0..3}
touch ./test-files/log{0..3}/access.log ./test-files/log{0..3}/error.log
