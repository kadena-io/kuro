#!/bin/sh

verbose=1

chirp() { [ $verbose ] && shout "$*"; return 0; }
shout() { echo "$0: $*" >&2;}
barf() { shout "$*"; exit 111; }
safe() { "$@" || barf "cannot $*"; }

types="(beta|aws)"
targets="(osx|ubuntu|centos|perform|dist)"
usage="\n
usage: [type] [target]\n
   \t type - required build type $types \n
   \t target  -  optional target $targets"

# User must specify the type of build: aws or beta.
# Beta and AWS builds include the same files, but are built with different
# limitations and, thus, different kill switch flags.
type="$1"
if [ -n "$type" ]; then
    [[ ! "$type" =~ $types ]] && barf $usage
else
   barf $usage
fi

# UNLIMITED="true" #if this line is not commented out, kill-switches will be ignored during the build

FLAG="kill-switch"             # beta is the default
if [[ "$type" = "aws" ]]; then
    FLAG="aws-kill-switch"
fi

if [ -n "$UNLIMITED" ]; then
    STACK_FLAG=""
    DOCKER_FLAG=""
else
    STACK_FLAG="--flag Kadena:$FLAG"
    DOCKER_FLAG="$FLAG"
fi
chirp "Building with STACK_FLAG = $STACK_FLAG"
chirp "Building with DOCKER_FLAG = $DOCKER_FLAG"

target="$2"
if [ -n "$target" ]; then
    [[ ! "$target" =~ $targets ]] && barf $usage
fi

chirp "Creating build directories"
safe rm -rf kadena-beta/aws && mkdir kadena-beta/aws
safe rm -rf kadena-beta/log && mkdir kadena-beta/log
safe rm -rf kadena-beta/conf && mkdir kadena-beta/conf
safe rm -rf kadena-beta/demo && mkdir kadena-beta/demo
safe rm -rf kadena-beta/setup && mkdir kadena-beta/setup

version=`egrep "^version:" kadena.cabal | sed -e 's/^version: *\(.*\) *$/\1/'`
if [ -z "$version" ]; then barf "Could not determine version"; fi
chirp "Building version $version"

if [ -z "$target" -o "$target" = "osx" ]; then

    chirp "Builing and Copying: OSX"
    rm ./kadena-beta/bin/osx/{genconfs,kadenaserver,kadenaclient}

    safe stack install $STACK_FLAG

    safe cp ./bin/genconfs ./kadena-beta/bin/osx/;
    safe cp ./bin/kadenaserver ./kadena-beta/bin/osx/;
    safe cp ./bin/kadenaclient ./kadena-beta/bin/osx/;

fi

if [ -z "$target" ]; then
    chirp "Copying: Conf"
    safe rm -rf ./kadena-beta/conf/*
    safe rm ./conf/*
    safe printf "\n\n4\n\n\n\n\n\n\n\n\n\n\n\n" | ./bin/genconfs
    safe cp ./conf/* ./kadena-beta/conf

    chirp "Clearing out the log"
    rm ./kadena-beta/log/*
fi

if [ -z "$target" -o "$target" = "ubuntu" ]; then

    chirp "Builing and Copying: Ubuntu 16.04"
    rm -rf ./kadena-beta/bin/ubuntu-16.04/{genconfs,kadenaserver,kadenaclient}
    safe docker build --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena-base:ubuntu-16.04 -f docker/ubuntu-base.Dockerfile .
    safe docker build --build-arg flag=$DOCKER_FLAG --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena:ubuntu-16.04 -f docker/ubuntu-build.Dockerfile .
    safe docker run -i -v ${PWD}:/work_dir kadena:ubuntu-16.04 << COMMANDS
cp -R /ubuntu-16.04 /work_dir/kadena-beta/bin
COMMANDS
    safe cp docker/ubuntu-base.Dockerfile kadena-beta/setup/

fi

if [ -z "$target" -o "$target" = "centos" ]; then

    chirp "Builing and Copying: CENTOS 6.8"
    rm -rf ./kadena-beta/bin/centos-6.8/{genconfs,kadenaserver,kadenaclient}
    safe docker build --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena-base:centos-6.8 -f docker/centos6-base.Dockerfile .
    safe docker build --build-arg flag=$DOCKER_FLAG --cpuset-cpus="0-3" --cpu-shares=1024 --memory=8g -t kadena:centos-6.8 -f docker/centos6-build.Dockerfile .
    safe docker run -i -v ${PWD}:/work_dir kadena:centos-6.8 << COMMANDS
cp -R /centos-6.8 /work_dir/kadena-beta/bin
COMMANDS
    safe cp docker/centos6-base.Dockerfile kadena-beta/setup/

fi

if [ -z "$target" -o "$target" = "perform" ]; then

    chirp "Builing and Copying: Performance Monitor"
    rm -rf ./kadena-beta/static/monitor/*
    safe cp -R monitor/ ./kadena-beta/static/monitor

fi

chirp "Copying Scripts and Ansible Playbooks"
safe rm -rf ./kadena-beta/aws/*
safe cp -r ./scripts/aws/* ./kadena-beta/aws
safe mv ./kadena-beta/aws/Ansible-README.md ./kadena-beta/docs
safe cp ./demo/{demo.repl,demo.pact,demo.yaml} ./kadena-beta/demo
safe cp ./scripts/setup-ubuntu-base.sh ./kadena-beta/setup

safe cp CHANGELOG.md kadena-beta/


chirp "taring the result"
if [[ "$type" = "aws" ]]; then
    safe cp -r kadena-beta kadena-aws
    safe rm -r kadena-aws/aws/edit_conf.yml
    safe rm -r kadena-aws/aws/templates/conf.j2
    safe rm -rf kadena-aws/bin/ubuntu-16.04/start-no-persistence.sh  # Not used
    safe rm -rf kadena-aws/bin/centos-6.8     # Not supported in AWS or Azure
    safe rm -rf kadena-aws/bin/osx            # Not supported in AWS or Azure
    safe tar cvz kadena-aws/* > kadena-aws-$version.tgz
    safe rm -rf kadena-aws
else
    safe tar cvz kadena-beta/* > kadena-beta-$version.tgz
fi

exit 0
