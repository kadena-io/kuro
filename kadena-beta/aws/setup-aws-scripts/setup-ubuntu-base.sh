#!/bin/bash

apt-get -y update && \
apt-get -y upgrade

apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 575159689BEFB442 && \
    echo 'deb http://download.fpcomplete.com/ubuntu xenial main' >> /etc/apt/sources.list.d/fpco.list && \
    apt-get -y update && \
    apt-get install -y libtool pkg-config build-essential autoconf automake rlwrap htop tmux libevent-dev libncurses-dev stack wget curl

wget https://github.com/tmux/tmux/releases/download/2.0/tmux-2.0.tar.gz && \
    tar -xvzf tmux-2.0.tar.gz && \
    cd tmux-2.0/ && \
    ./configure && \
    make install && \
    cd .. && rm -rf tmux-2.0*

wget https://download.libsodium.org/libsodium/releases/libsodium-1.0.16.tar.gz && \
    tar -xvf libsodium-1.0.16.tar.gz  && \
    cd libsodium-1.0.16  && \
    ./configure  && \
    make && \
    make install && \
    cd .. && rm -rf libsodium-1.0.16*

cd && touch ./build-exports && \
    echo '/usr/local/lib' >> /etc/ld.so.conf.d/libsodium.conf && \
    echo 'export sodium_CFLAGS="-I/usr/local/include"' >> ./build-exports && \
    echo 'export sodium_LIBS="-L/usr/local/lib"' >> ./build-exports && \
    echo 'export CPATH=/usr/local/include' >> ./build-exports && \
    echo 'export LIBRARY_PATH=/usr/local/lib' >> ./build-exports && \
    echo 'export LD_LIBRARY_PATH=/usr/local/lib' >> ./build-exports && \
    echo 'export LD_RUN_PATH=/usr/local/lib' >> ./build-exports && \
    echo 'export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig' >> ./build-exports && \
    echo 'export CFLAGS=$(pkg-config --cflags libsodium)' >> ./build-exports && \
    echo 'export LDFLAGS=$(pkg-config --libs libsodium)' >> ./build-exports

cd && source ./build-exports && \
    ldconfig && \
    wget https://archive.org/download/zeromq_4.1.4/zeromq-4.1.4.tar.gz && \
    tar -xzvf zeromq-4.1.4.tar.gz && \
    cd zeromq-4.1.4 && \
    ./configure --with-libsodium && \
    make install && \
    cd .. && rm -rf zeromq-4.1.4*

cd && wget http://dev.mysql.com/get/mysql-apt-config_0.6.0-1_all.deb && \
    dpkg -i mysql-apt-config_0.6.0-1_all.deb && \
    apt-get -y update && \
    apt-get -y --allow-unauthenticated install mysql-server libmysqlclient20 && \
    cd && rm -rf mysql-apt-config*

stack --resolver lts-8.15 setup

apt-get install -y build-essential wget libodbc1 unixodbc unixodbc-dev freetds-bin tdsodbc
