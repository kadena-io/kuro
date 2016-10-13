FROM local/kadena-base-ubuntu

COPY ./stack.yaml /kadena/stack.yaml
COPY ./submodules/ /kadena/submodules/
COPY ./kadena.cabal /kadena/kadena.cabal

RUN cd /kadena && stack build --only-snapshot

COPY ./Setup.hs /kadena/Setup.hs
COPY ./conf /kadena/conf
COPY ./demo /kadena/demo
COPY ./executables /kadena/executables
COPY ./kadenaclient.sh /kadena/kadenaclient.sh
COPY ./demo /kadena/demo
COPY ./src /kadena/src
COPY ./tests /kadena/tests
COPY ./LICENSE /kadena/LICENSE

RUN bash -c "mkdir /kadena/log && \
    cd && source ./build-exports && \
    cd /kadena && \
    stack build && \
    stack install"

RUN mkdir -p /payments-demo/demo && \
    cp ~/.local/bin/* /payments-demo && \
    cp -R /kadena/log /payments-demo && \
    cp /kadena/demo/demo.json /payments-demo/demo && \
    cp /kadena/demo/demo.pact /payments-demo/demo && \
    cp /kadena/demo/start.sh /payments-demo/demo && \
    cp /kadena/kadenaclient.sh /payments-demo

CMD ["/bin/bash"]
