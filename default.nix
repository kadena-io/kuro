{ killSwitch ? false
, rpRef ? "f3ff81d519b226752c83eefd4df6718539c3efdc"
, rpSha ?  "1ijxfwl36b9b2j4p9j3bv8vf7qfi570m1c5fjyvyac0gy0vi5g8j" }:

let rp = builtins.fetchTarball {
  url = "https://github.com/reflex-frp/reflex-platform/archive/${rpRef}.tar.gz";
  sha256 = rpSha;
};

in
  (import rp {}).project ({ pkgs, ... }: {
    name = "kadena-umbrella";
    overrides = self: super:
      let ridley-src = pkgs.fetchFromGitHub {
            owner = "kadena-io";
            repo = "ridley";
            rev = "1227fff4559586bd128fb41bd129c4440b6102ff";
            sha256 = "0v0mg6xw4p2ykvavs4fcddyllvbgslxvrlhz3ja3bgkw2sv0a6hv";
          };
          #katip 0.6.3.0 was not being found via callHackage for some reason...
          katip-src = pkgs.fetchFromGitHub {
            owner = "soostone";
            repo = "katip";
            rev = "e04f087f5058f815b37b6a9b2ceafb366e45eec2";
            sha256 = "1pqc8ighwhhmswng40cvvnf10y8vaf8842br5c6mn2fzadvgn80g";
          };

       in with pkgs.haskell.lib; {

            # the following packages are not in the current nixpgks set
            algebraic-graphs = self.callHackage "algebraic-graphs" "0.2" {};
            bloomfilter = self.callHackage "bloomfilter" "2.0.1.0" {};
            # test for bound failing...
            bound = dontCheck (self.callHackage "bound" "2.0.1" {});
            compactable = self.callHackage "compactable" "0.1.2.2" {};
            concurrent-extra = dontCheck (doJailbreak (self.callHackage "concurrent-extra" "0.7.0.10" {}));
            ed25519-donna = self.callHackage "ed25519-donna" "0.1.1" {};
            lz4 = self.callHackage "lz4" "0.2.3.1" {};
            monad-gen = self.callHackage "monad-gen" "0.3.0.1" {};
            prometheus = self.callHackage "prometheus" "2.1.0" {};
            unagi-chan = self.callHackage "unagi-chan" "0.4.0.0" {};
            crackNum = self.callHackage "crackNum" "2.2" {};
            floatinghex = self.callHackage "floatinghex" "0.4" {};

            #zeromq4-haskell tests failing
            #zeromq4-haskell = dontCheck (self.callHackage "zeromq4-haskell" "0.7.0" {});
            zeromq4-haskell = dontCheck super.zeromq4-haskell;

            wai-middleware-metrics = dontCheck super.wai-middleware-metrics;


            #cacophony 0.10.1 was not being found via callHackage for some reason...
            cacophony = self.callCabal2nix "cacophony" (pkgs.fetchFromGitHub {
              owner = "centromere";
              repo = "cacophony";
              rev = "34e4c4296f9b259d00c47c866d3ba843e7f90996";
              sha256 = "17j1mpbmr1fwx98y3x9g5xykmv354kwm9frfvi4vlzxg875ay7hx";
            }) {};


            pact = addBuildDepend (self.callCabal2nix "pact" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "pact";
              rev = "ac0f72ed48f6e17dadedd76ee46e87c58de9a3f4";
              sha256 = "0y1c0kvsvhc5akgsyi5sspinjln37gaprbm54wh8s9vfysxq3b7m";
            }) {}) pkgs.z3;

            pact-persist = self.callCabal2nix "pact-persist" (builtins.fetchGit {
              url = "ssh://git@github.com/kadena-io/pact-persist.git";
              rev = "289864150fce306767ad4865e61f96a5c81f308e";
              ref = "master";
            }) {};

            thyme = dontCheck (self.callCabal2nix "thyme" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "thyme";
              rev = "6ee9fcb026ebdb49b810802a981d166680d867c9";
              sha256 = "09fcf896bs6i71qhj5w6qbwllkv3gywnn5wfsdrcm0w1y6h8i88f";
            }) {});

            hdbc-odbc = self.callCabal2nix "hdbc-odbc" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "hdbc-odbc";
              rev = "79ffd1f5060d2c8b5cbdfd4eba8ae6414372d6b7";
              sha256 = "0000000000000000000000000000000000000000000000000000";
            }) {};

            sbv = self.callCabal2nix "sbv" (pkgs.fetchFromGitHub {
              owner = "LeventErkok";
              repo = "sbv";
              rev = "3dc60340634c82f39f6c5dca2b3859d10925cfdf";
              sha256 = "18xcxg1h19zx6gdzk3dfs87447k3xjqn40raghjz53bg5k8cdc31";
            }) {};

            #ekg-prometheus-adapter = self.callCabal2nix "ekg-prometheus-adapter" ../../../prometheus/ekg-prometheus-adapter {};
            ekg-prometheus-adapter = self.callCabal2nix "ekg-prometheus-adapter" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "ekg-prometheus-adapter";
              rev = "bd93dd5596d626b121f567bb24c0741fa0c8ccdd";
              sha256 = "03igbrzb9xh2aryj9srmd4ycn8zidxynkvirv8sn4912b8pwgssz";
            }) {};

            ridley = dontHaddock (dontCheck (self.callCabal2nix "ridley" (ridley-src + /ridley) {}));

            katip = self.callCabal2nix "katip" "${katip-src}/katip" {};

####################################################################################################
            # QuickCheck = dontCheck (self.callHackage "QuickCheck" "2.11.3" {});
            # aeson = self.callHackage "aeson" "1.0.2.1" {};
#            cryptonite = self.callHackage "cryptonite" "0.23" {};
#
#            haskeline = self.callHackage "haskeline" "0.7.4.2" {};
#            katip = self.callHackage "katip" "0.6.3.0" {};
#            #ridley = dontCheck (self.callHackage "ridley" "0.3.1.2" {});
#
#            criterion = dontCheck (self.callCabal2nix "criterion" (pkgs.fetchFromGitHub {
#              owner = "bos";
#              repo = "criterion";
#              rev = "5a704392b670c189475649c32d05eeca9370d340";
#              sha256 = "1kp0l78l14w0mmva1gs9g30zdfjx4jkl5avl6a3vbww3q50if8pv";
#            }) {});
#
#            # Version 1.6.4, needed by weeder, not in callHackage yet
#            extra = dontCheck (self.callCabal2nix "extra" (pkgs.fetchFromGitHub {
#              owner = "ndmitchell";
#              repo = "extra";
#              rev = "4064bfa7e48a7f1b79f791560d51dbefed879219";
#              sha256 = "1p7rc5m70rkm1ma8gnihfwyxysr0n3wxk8ijhp6qjnqp5zwifhhn";
#            }) {});
            #pact-persist = self.callCabal2nix "pact-persist" (builtins.fetchGit {
            #  url = "ssh://git@github.com/kadena-io/pact-persist.git";
              # ref = "pact-2.4.x-upgrade";
              # This rev must be on the above branch ref
              # rev = "d0657343da4347637e9419096e324edf66a7c543";
              # Uncomment when nix and mysql branch merged into master.
              # rev = "1db11ffbc806b2e75b63ff64a7fcf6b29f4f073d"
              # ref = "mysql-nix-merge";

            # dontCheck is here because a couple tests were failing
            #statistics = dontCheck (self.callCabal2nix "statistics" (pkgs.fetchFromGitHub {
            #  owner = "bos";
            #  repo = "statistics";
            #  rev = "1ed1f2844c5a2209f5ea72e60df7d14d3bb7ac1a";
            #  sha256 = "1jjmdhfn198pfl3k5c4826xddskqkfsxyw6l5nmwrc8ibhhnxl7p";
            #}) {});

            ## weeder = self.callHackage "weeder" "1.0.5" {};
            #weeder = self.callCabal2nix "weeder" (pkgs.fetchFromGitHub {
            #  owner = "ndmitchell";
            #  repo = "weeder";
            #  rev = "56b46fe97782e86198f31c574ac73c8c966fee05";
            #  sha256 = "005ks2xjkbypq318jd0s4896b9wa5qg3jf8a1qgd4imb4fkm3yh7";
            #}) {};
####################################################################################################

          };
    packages = {
      kadena = builtins.filterSource
        (path: type: !(builtins.elem (baseNameOf path)
           ["result" "dist" "dist-ghcjs" ".git"]))
        ./.;
    };

    shells = {
      ghc = ["kadena"];
    };

    shellToolOverrides = ghc: super: {
      z3 = pkgs.z3;
      stack = pkgs.stack;
    };
  })
