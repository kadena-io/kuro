FROM local/kadena-base-ubuntu

ADD ./readonly_keys/* /root/.ssh/
ADD ./Setup.hs /kadena/Setup.hs
ADD ./conf /kadena/conf
ADD ./demo /kadena/demo
ADD ./executables /kadena/executables
ADD ./kadena.cabal /kadena/kadena.cabal
ADD ./kadenaclient.sh /kadena/kadenaclient.sh
ADD ./demo /kadena/demo
ADD ./src /kadena/src
ADD ./tests /kadena/tests
ADD ./stack.yaml /kadena/stack.yaml

RUN mkdir /kadena/log && \
    echo 'IdentityFile ~/.ssh/functional_rsa' >> ~/.ssh/config && \
    chmod 400 ~/.ssh/* && \
    chmod g-w ~/.ssh/* && \
    chmod 400 ~/.ssh && \
    chmod g-w ~/.ssh && \
    ls -lart ~/.ssh && \
    export GIT_SSH_COMMAND="ssh -vvv" && \
    set GIT_SSH_COMMAND="ssh -vvv" && \
    cd /kadena && stack build -v && stack install


CMD ["/bin/bash"]
