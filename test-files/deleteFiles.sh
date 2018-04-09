#!/bin/sh
pwd
rm ./test-files/log/*.sqlite* ./test-files/log/access.log ./test-files/log/error.log ./test-files/log/client.log
touch ./test-files/log/access.log ./test-files/log/error.log
