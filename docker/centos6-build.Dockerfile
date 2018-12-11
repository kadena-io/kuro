FROM kadena-base:centos-6.8

COPY ./stack-docker.yaml /kadena/stack.yaml
COPY ./submodules/ /kadena/submodules/
COPY ./kadena.cabal /kadena/kadena.cabal

RUN source /home/build-exports && ldconfig && cd /kadena && stack build --only-snapshot

RUN source /home/build-exports && ldconfig && cd /kadena && stack build --only-dependencies

COPY ./Setup.hs /kadena/Setup.hs
COPY ./conf /kadena/conf
COPY ./demo /kadena/demo
COPY ./executables /kadena/executables
COPY ./kadenaclient.sh /kadena/kadenaclient.sh
COPY ./demo /kadena/demo
COPY ./src /kadena/src
COPY ./tests /kadena/tests
COPY ./LICENSE /kadena/LICENSE

ARG flag

RUN bash -c "mkdir -p /kadena/log && \
    cd && source /home/build-exports && ldconfig && \
    cd /kadena && \
    stack install --flag kadena:$flag"


RUN mkdir -p /centos-6.8 && \
    cp kadena/bin/genconfs /centos-6.8 && \
    cp kadena/bin/kadenaserver /centos-6.8 && \
    cp kadena/bin/kadenaclient /centos-6.8

CMD ["/bin/bash"]
