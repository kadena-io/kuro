FROM ubuntu:16.04
MAINTAINER Will <will@kadena.io>

RUN apt-get -y update && apt-get -y upgrade

RUN apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 575159689BEFB442 && \
    echo 'deb http://download.fpcomplete.com/ubuntu xenial main' >> /etc/apt/sources.list.d/fpco.list && \
    apt-get -y update && \
    apt-get install -y libtool pkg-config build-essential autoconf automake rlwrap htop tmux libevent-dev libncurses-dev stack wget curl

RUN wget https://github.com/tmux/tmux/releases/download/2.0/tmux-2.0.tar.gz && \
    tar -xvzf tmux-2.0.tar.gz && \
    cd tmux-2.0/ && \
    ./configure && \
    make install && \
    cd .. && rm -rf tmux-2.0*

RUN wget https://download.libsodium.org/libsodium/releases/libsodium-1.0.11.tar.gz && \
    tar -xvf libsodium-1.0.11.tar.gz  && \
    cd libsodium-1.0.11  && \
    ./configure  && \
    make && \
    make install && \
    cd .. && rm -rf libsodium-1.0.11*

RUN cd && touch ./build-exports && \
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

RUN bash -c "cd && source ./build-exports && \
    ldconfig && \
    wget https://archive.org/download/zeromq_4.1.4/zeromq-4.1.4.tar.gz && \
    tar -xzvf zeromq-4.1.4.tar.gz && \
    cd zeromq-4.1.4 && \
    ./configure --with-libsodium && \
    make install && \
    cd .. && rm -rf zeromq-4.1.4* "

RUN stack --resolver lts-6.12 setup

RUN apt-get install -y build-essential wget libodbc1 unixodbc unixodbc-dev freetds-bin tdsodbc

CMD ["/bin/bash"]
