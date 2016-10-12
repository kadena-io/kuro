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

RUN mkdir /demo && \
    cp ~/.local/bin/* /demo && \
    cp -R /kadena/log /demo && \
    cp -R /kadena/demo /demo/demo && \
    cp /kadena/kadenaclient.sh /demo

CMD ["/bin/bash"]
