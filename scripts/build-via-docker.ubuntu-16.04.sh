#!/bin/sh

chirp() { [ $verbose ] && shout "$*"; return 0; }

shout() { echo "$0: $*" >&2;}

barf() { shout "$*"; exit 111; }

safe() { "$@" || barf "cannot $*"; }

safe rm -rf ./payments-demo/*

safe docker build --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena-base:ubuntu-16.04 -f docker/ubuntu-base.Dockerfile .

safe docker build --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena:ubuntu-16.04 -f docker/ubuntu-build.Dockerfile .

safe docker run -i -v ${PWD}:/work_dir kadena:ubuntu-16.04 << COMMANDS
cp -R /payments-demo /work_dir
COMMANDS

safe cd ./monitor

safe npm run build

safe cd ..

safe cp -R monitor/public payments-demo

safe tar -cvz payments-demo/* > payments-demo.tgz

exit 0
