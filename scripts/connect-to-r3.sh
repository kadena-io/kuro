#!/bin/sh

chirp() { [ $verbose ] && shout "$*"; return 0; }

shout() { echo "$0: $*" >&2;}

barf() { shout "$*"; exit 111; }

safe() { "$@" || barf "cannot $*"; }

ssh -y -L 8000:localhost:8000 -L 8001:localhost:8001 -L 8002:localhost:8002 -L 8003:localhost:8003 -L 10080:localhost:10080 -L 10081:localhost:10081 -L 10082:localhost:10082 -L 10083:localhost:10083 kadena@kadena-kadena.gcl.r3cev.com
