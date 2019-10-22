FROM kadena-base:ubuntu-16.04

COPY ./stack-docker.yaml /kadena/stack.yaml
COPY ./submodules/ /kadena/submodules/
COPY ./kadena.cabal /kadena/kadena.cabal

RUN cd /kadena && stack build --only-snapshot && stack build --only-dependencies

COPY ./Setup.hs /kadena/Setup.hs
COPY ./conf /kadena/conf
COPY ./demo /kadena/demo
COPY ./executables /kadena/executables
COPY ./kadenaclient.sh /kadena/kadenaclient.sh
COPY ./demo /kadena/demo
COPY ./src /kadena/src
COPY ./tests /kadena/tests
COPY ./LICENSE /kadena/LICENSE

ARG stack_flag

RUN bash -c "mkdir -p /kadena/log && \
    cd && source ./build-exports && \
    cd /kadena && \
    stack install $stack_flag"

RUN mkdir -p /ubuntu-16.04 && \
    cp /kadena/bin/genconfs /ubuntu-16.04 && \
    cp /kadena/bin/kadenaserver /ubuntu-16.04 && \
    cp /kadena/bin/kadenaclient /ubuntu-16.04

CMD ["/bin/bash"]
