FROM centos:6
MAINTAINER Will <will@kadena.io>

RUN yum -y upgrade && \
    find / -iname gmp && \
    yum -y install wget which curl make uuid-devel pkgconfig libtool gcc-c++ glibc* perl make automake gcc gmp-devel libffi zlib xz tar git gnupg zlib-devel&& \
    yum -y groupinstall "development tools"

RUN mkdir -p /tmp && \
    cd /tmp && \
    wget http://download.fedoraproject.org/pub/epel/6/x86_64/epel-release-6-8.noarch.rpm && \
    rpm -ivh epel-release-6-8.noarch.rpm && \
    curl -sSL https://s3.amazonaws.com/download.fpcomplete.com/centos/6/fpco.repo | tee /etc/yum.repos.d/fpco.repo && \
    yum -y update

RUN cd /tmp && \
    wget https://download.libsodium.org/libsodium/releases/libsodium-1.0.16.tar.gz && \
    tar -xvf libsodium-1.0.16.tar.gz  && \
    cd libsodium-1.0.16  && \
    ./configure  && \
    make && \
    make install && \
    touch /home/build-exports && \
    echo '/usr/local/lib' > tee -a /etc/ld.so.conf.d/libsodium.conf && \
    echo 'export sodium_CFLAGS="-I/usr/local/include"' >> /home/build-exports && \
    echo 'export sodium_LIBS="-L/usr/local/lib"' >> /home/build-exports && \
    echo 'export CPATH=/usr/local/include' >> /home/build-exports && \
    echo 'export LIBRARY_PATH=/usr/local/lib' >> /home/build-exports && \
    echo 'export LD_LIBRARY_PATH=/usr/local/lib' >> /home/build-exports && \
    echo 'export LD_RUN_PATH=/usr/local/lib' >> /home/build-exports && \
    echo 'export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig' >> /home/build-exports && \
    echo 'export CFLAGS=$(pkg-config --cflags libsodium)' >> /home/build-exports && \
    echo 'export LDFLAGS=$(pkg-config --libs libsodium)' >> /home/build-exports

RUN source /home/build-exports && \
    ldconfig && \
    cd tmp && \
    wget https://archive.org/download/zeromq_4.1.4/zeromq-4.1.4.tar.gz && \
    tar -xzvf zeromq-4.1.4.tar.gz && \
    cd zeromq-4.1.4 && \
    ./configure --with-libsodium && \
    make install

RUN yum -y install stack && stack --resolver lts-8.15 setup

RUN yum -y install unixODBC unixODBC-devel

CMD ["/bin/bash"]
