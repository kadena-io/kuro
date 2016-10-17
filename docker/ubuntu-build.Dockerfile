FROM kadena-base:ubuntu-16.04

COPY ./stack.yaml /kadena/stack.yaml
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

RUN bash -c "mkdir -p /kadena/log && \
    cd && source ./build-exports && \
    cd /kadena && \
    stack build --flag kadena:kill-switch && \
    stack install"

RUN mkdir -p /payments-demo/demo && \
    mkdir -p /payments-demo/bin && \
    cp ~/.local/bin/* /payments-demo/bin && \
    cp -R /kadena/log /payments-demo && \
    cp /kadena/demo/demo.json /payments-demo/demo && \
    cp /kadena/demo/demo.pact /payments-demo/demo && \
    cp /kadena/demo/start.sh /payments-demo/demo && \
    cp /kadena/kadenaclient.sh /payments-demo

CMD ["/bin/bash"]
