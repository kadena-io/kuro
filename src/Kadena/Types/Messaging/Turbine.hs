Welcome to the Emacs shell

~/kadena/kadena/src/Kadena/PreProc $ cd ../..
~/kadena/kadena/src $ ls
Apps  Kadena
~/kadena/kadena/src $ cd ..
~/kadena/kadena $ ls
CHANGELOG.md  LICENSE    Setup.hs  aws-conf  conf  demo    dist           docker       kadena-beta   kadenaclient.sh  monitor         scripts  stack-docker.yaml  static      test-files
HLint.hs      README.md  TAGS      bin       data  demoui  dist-newstyle  executables  kadena.cabal  log              prometheus.yml  src      stack.yaml         submodules  tests
~/kadena/kadena $ git stash
Saved working directory and index state WIP on feat/config-change-2: faeeda9 Execution.Types -> Types.Execution
~/kadena/kadena $ cd src/Kadena/
~/kadena/kadena/src/Kadena $ ls
Command.hs  Config.hs     ConfigChange.hs  Event.hs  Execution  History  Log.hs      Messaging   PreProc  Sender  Types     Util
Config      ConfigChange  Consensus        Evidence  HTTP       Log      Message.hs  Monitoring  Private  Spec    Types.hs  
~/kadena/kadena/src/Kadena $ cd Types/
~/kadena/kadena/src/Kadena/Types $ ls
Base.hs     Comms.hs   ConfigChange.hs  Entity.hs  Evidence.hs   History.hs  Log.hs   Message.hs  PactDB.hs  Sqlite.hs
Command.hs  Config.hs  Dispatch.hs      Event.hs   Execution.hs  KeySet.hs   Message  Metric.hs   Spec.hs    Types.hs
~/kadena/kadena/src/Kadena/Types $ cd 
~ $ ls
Desktop  Documents  Downloads  Library  Movies  Music  Pictures  Public  haskell  kadena  nixpkgs
~ $ cd -
~/kadena/kadena/src/Kadena/Types $ ls
Base.hs     Comms.hs   ConfigChange.hs  Entity.hs  Evidence.hs   History.hs  Log.hs   Message.hs  PactDB.hs  Sqlite.hs
Command.hs  Config.hs  Dispatch.hs      Event.hs   Execution.hs  KeySet.hs   Message  Metric.hs   Spec.hs    Types.hs
~/kadena/kadena/src/Kadena/Types $ mkdir Messaging
~/kadena/kadena/src/Kadena/Types $ cd ~/kadena/kadena/
~/kadena/kadena $ stack build
Copying from /Users/emilypi/kadena/kadena/.stack-work/install/x86_64-osx/lts-8.15/8.0.2/bin/genconfs to /Users/emilypi/kadena/kadena/bin/genconfs
Copying from /Users/emilypi/kadena/kadena/.stack-work/install/x86_64-osx/lts-8.15/8.0.2/bin/kadenaclient to /Users/emilypi/kadena/kadena/bin/kadenaclient
Copying from /Users/emilypi/kadena/kadena/.stack-work/install/x86_64-osx/lts-8.15/8.0.2/bin/kadenaserver to /Users/emilypi/kadena/kadena/bin/kadenaserver

Copied executables to /Users/emilypi/kadena/kadena/bin:
- genconfs
- kadenaclient
- kadenaserver

Warning: Installation path
         /Users/emilypi/kadena/kadena/bin
         not found on the PATH environment variable.
~/kadena/kadena $ ls
CHANGELOG.md  README.md  aws-conf  data    dist           executables   kadenaclient.sh  prometheus.yml  stack-docker.yaml  submodules
HLint.hs      Setup.hs   bin       demo    dist-newstyle  kadena-beta   log              scripts         stack.yaml         test-files
LICENSE       TAGS       conf      demoui  docker         kadena.cabal  monitor          src             static             tests
~/kadena/kadena $ cd src/Kadena/Types/Messaging/
~/kadena/kadena/src/Kadena/Types/Messaging $ ls
~/kadena/kadena/src/Kadena/Types/Messaging $ mkdir Turbine
~/kadena/kadena/src/Kadena/Types/Messaging $ ls
Turbine
~/kadena/kadena/src/Kadena/Types/Messaging $ cd tur
No such directory found via CDPATH environment variable
~/kadena/kadena/src/Kadena/Types/Messaging $ cd Turbine/
~/kadena/kadena/src/Kadena/Types/Messaging/Turbine $ ls
Types.hs
~/kadena/kadena/src/Kadena/Types/Messaging/Turbine $ stack build
kadena-1.1.2.0: unregistering (local file changes: kadena.cabal src/Kadena/Messaging/Turbine/Types.hs src/Kadena/Types.hs src/Kadena/Types/Messaging...)
kadena-1.1.2.0: configure (lib + exe)
Configuring kadena-1.1.2.0...
kadena-1.1.2.0: build (lib + exe)
Preprocessing library kadena-1.1.2.0...
[44 of 79] Compiling Kadena.PreProc.Types ( src/Kadena/PreProc/Types.hs, .stack-work/dist/x86_64-osx/Cabal-1.24.2.0/build/Kadena/PreProc/Types.o )
[45 of 79] Compiling Kadena.Types.Dispatch ( src/Kadena/Types/Dispatch.hs, .stack-work/dist/x86_64-osx/Cabal-1.24.2.0/build/Kadena/Types/Dispatch.o ) [TH]
[48 of 79] Compiling Kadena.Types.Spec ( src/Kadena/Types/Spec.hs, .stack-work/dist/x86_64-osx/Cabal-1.24.2.0/build/Kadena/Types/Spec.o ) [TH]
[52 of 79] Compiling Kadena.HTTP.ApiServer ( src/Kadena/HTTP/ApiServer.hs, .stack-work/dist/x86_64-osx/Cabal-1.24.2.0/build/Kadena/HTTP/ApiServer.o ) [TH]
[53 of 79] Compiling Kadena.Sender.Service ( src/Kadena/Sender/Service.hs, .stack-work/dist/x86_64-osx/Cabal-1.24.2.0/build/Kadena/Sender/Service.o ) [TH]
[54 of 79] Compiling Kadena.Types     ( src/Kadena/Types.hs, .stack-work/dist/x86_64-osx/Cabal-1.24.2.0/build/Kadena/Types.o )

/Users/emilypi/kadena/kadena/src/Kadena/Types.hs:18:1: error:
    Failed to load interface for ‘Kadena.Types.Messaging’
    Use -v to see a list of the files searched for.

--  While building custom Setup.hs for package kadena-1.1.2.0 using:
      /Users/emilypi/.stack/setup-exe-cache/x86_64-osx/Cabal-simple_mPHDZzAJ_1.24.2.0_ghc-8.0.2 --builddir=.stack-work/dist/x86_64-osx/Cabal-1.24.2.0 build lib:kadena exe:genconfs exe:kadenaclient exe:kadenaserver --ghc-options " -ddump-hi -ddump-to-file"
    Process exited with code: ExitFailure 1
~/kadena/kadena/src/Kadena/Types/Messaging/Turbine $ stack build
kadena-1.1.2.0: configure (lib + exe)
Configuring kadena-1.1.2.0...
kadena-1.1.2.0: build (lib + exe)
Preprocessing library kadena-1.1.2.0...
Cabal-simple_mPHDZzAJ_1.24.2.0_ghc-8.0.2: can't find source for
Kadena/Types/Messaging/Turbine in src,
.stack-work/dist/x86_64-osx/Cabal-1.24.2.0/build/autogen

--  While building custom Setup.hs for package kadena-1.1.2.0 using:
      /Users/emilypi/.stack/setup-exe-cache/x86_64-osx/Cabal-simple_mPHDZzAJ_1.24.2.0_ghc-8.0.2 --builddir=.stack-work/dist/x86_64-osx/Cabal-1.24.2.0 build lib:kadena exe:genconfs exe:kadenaclient exe:kadenaserver --ghc-options " -ddump-hi -ddump-to-file"
    Process exited with code: ExitFailure 1
~/kadena/kadena/src/Kadena/Types/Messaging/Turbine $ ls
Types.hs
~/kadena/kadena/src/Kadena/Types/Messaging/Turbine $ mv Types.hs Turbine.hs
~/kadena/kadena/src/Kadena/Types/Messaging/Turbine $ ls
Turbine.hs
~/kadena/kadena/src/Kadena/Types/Messaging/Turbine $ stack build
kadena-1.1.2.0: build (lib + exe)
Preprocessing library kadena-1.1.2.0...
Cabal-simple_mPHDZzAJ_1.24.2.0_ghc-8.0.2: can't find source for
Kadena/Types/Messaging/Turbine in src,
.stack-work/dist/x86_64-osx/Cabal-1.24.2.0/build/autogen

--  While building custom Setup.hs for package kadena-1.1.2.0 using:
      /Users/emilypi/.stack/setup-exe-cache/x86_64-osx/Cabal-simple_mPHDZzAJ_1.24.2.0_ghc-8.0.2 --builddir=.stack-work/dist/x86_64-osx/Cabal-1.24.2.0 build lib:kadena exe:genconfs exe:kadenaclient exe:kadenaserver --ghc-options " -ddump-hi -ddump-to-file"
    Process exited with code: ExitFailure 1
~/kadena/kadena/src/Kadena/Types/Messaging/Turbine $ ls
Turbine.hs
~/kadena/kadena/src/Kadena/Types/Messaging/Turbine $ mv Turbine.hs ../
~/kadena/kadena/src/Kadena/Types/Messaging/Turbine $ ls
~/kadena/kadena/src/Kadena/Types/Messaging/Turbine $ cd ..
~/kadena/kadena/src/Kadena/Types/Messaging $ ls
Turbine  Turbine.hs
~/kadena/kadena/src/Kadena/Types/Messaging $ rm -rf Turbine/
~/kadena/kadena/src/Kadena/Types/Messaging $ ls
Turbine.hs
~/kadena/kadena/src/Kadena/Types/Messaging $ stack build
kadena-1.1.2.0: build (lib + exe)
Preprocessing library kadena-1.1.2.0...
Module imports form a cycle:
         module ‘Kadena.Types’ (src/Kadena/Types.hs)
        imports ‘Kadena.Types.Messaging.Turbine’ (src/Kadena/Types/Messaging/Turbine.hs)
  which imports ‘Kadena.Types’ (src/Kadena/Types.hs)

--  While building custom Setup.hs for package kadena-1.1.2.0 using:
      /Users/emilypi/.stack/setup-exe-cache/x86_64-osx/Cabal-simple_mPHDZzAJ_1.24.2.0_ghc-8.0.2 --builddir=.stack-work/dist/x86_64-osx/Cabal-1.24.2.0 build lib:kadena exe:genconfs exe:kadenaclient exe:kadenaserver --ghc-options " -ddump-hi -ddump-to-file"
    Process exited with code: ExitFailure 1
~/kadena/kadena/src/Kadena/Types/Messaging $ stack build
kadena-1.1.2.0: build (lib + exe)
Preprocessing library kadena-1.1.2.0...
Module imports form a cycle:
         module ‘Kadena.Types’ (src/Kadena/Types.hs)
        imports ‘Kadena.Types.Messaging.Turbine’ (src/Kadena/Types/Messaging/Turbine.hs)
  which imports ‘Kadena.Types’ (src/Kadena/Types.hs)

--  While building custom Setup.hs for package kadena-1.1.2.0 using:
      /Users/emilypi/.stack/setup-exe-cache/x86_64-osx/Cabal-simple_mPHDZzAJ_1.24.2.0_ghc-8.0.2 --builddir=.stack-work/dist/x86_64-osx/Cabal-1.24.2.0 build lib:kadena exe:genconfs exe:kadenaclient exe:kadenaserver --ghc-options " -ddump-hi -ddump-to-file"
    Process exited with code: ExitFailure 1
~/kadena/kadena/src/Kadena/Types/Messaging $ stack build