#!/bin/sh

verbose=1

chirp() { [ $verbose ] && shout "$*"; return 0; }
shout() { echo "$0: $*" >&2;}
barf() { shout "$*"; exit 111; }
safe() { "$@" || barf "cannot $*"; }

chirp "Copying: Conf"
safe rm -rf ./kadena-beta/conf/*
safe cp ./conf/* ./kadena-beta/conf

chirp "Builing and Copying: OSX"
safe rm -rf ./kadena-beta/bin/osx/*
safe stack install
safe cp `which genconfs` ./kadena-beta/bin/osx/;
safe cp `which kadenaserver` ./kadena-beta/bin/osx/;
safe cp `which kadenaclient` ./kadena-beta/bin/osx/;

chirp "Builing and Copying: Ubuntu"
safe rm -rf ./kadena-beta/bin/ubuntu-16.04/*
safe docker build --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena-base:ubuntu-16.04 -f docker/ubuntu-base.Dockerfile .
safe docker build --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena:ubuntu-16.04 -f docker/ubuntu-build.Dockerfile .
safe docker run -i -v ${PWD}:/work_dir kadena:ubuntu-16.04 << COMMANDS
cp -R /ubuntu-16.04 /work_dir/kadena-beta/bin
COMMANDS

chirp "Builing and Copying: Performance Monitor"
safe rm -rf ./kadena-beta/static/monitor/*
safe cd ./monitor
safe npm run build
safe cd ..
safe cp -R monitor/public/* ./kadena-beta/static/monitor/

exit 0
