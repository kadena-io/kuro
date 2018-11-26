{ killSwitch ? false
, rpRef ? "80236ad3769602813d1c963e2bd90edd3147734b"
, rpSha ?  "13l46z12i1bdwl9w76vl0cw860syvjkm8a4zgc0610f98h18dqh1" }:

let rp = (import <nixpkgs> {}).fetchFromGitHub {
           owner = "adetokunbo";
           repo = "reflex-platform";
           rev = rpRef;
           sha256 = rpSha;
         };

in
  (import rp {}).project ({ pkgs, ... }: {
    name = "kadena-umbrella";
    overrides = self: super:
      let guardGhcjs = p: if self.ghc.isGhcjs or false then null else p;
       in with pkgs.haskell.lib; {
            # QuickCheck = dontCheck (self.callHackage "QuickCheck" "2.11.3" {});
            # aeson = self.callHackage "aeson" "1.0.2.1" {};

            # cacophony requires cryptonite >= 0.22 but doesn't supply a lower bound
            # cacophony = dontCheck (self.callHackage "cacophony" "0.8.0" {});

            cryptonite = self.callHackage "cryptonite" "0.23" {};

            haskeline = self.callHackage "haskeline" "0.7.4.2" {};
            katip = doJailbreak (self.callHackage "katip" "0.3.1.4" {});
            #ridley = dontCheck (self.callHackage "ridley" "0.3.1.2" {});

            criterion = dontCheck (self.callCabal2nix "criterion" (pkgs.fetchFromGitHub {
              owner = "bos";
              repo = "criterion";
              rev = "5a704392b670c189475649c32d05eeca9370d340";
              sha256 = "1kp0l78l14w0mmva1gs9g30zdfjx4jkl5avl6a3vbww3q50if8pv";
            }) {});

            # Version 1.6.4, needed by weeder, not in callHackage yet
            extra = dontCheck (self.callCabal2nix "extra" (pkgs.fetchFromGitHub {
              owner = "ndmitchell";
              repo = "extra";
              rev = "4064bfa7e48a7f1b79f791560d51dbefed879219";
              sha256 = "1p7rc5m70rkm1ma8gnihfwyxysr0n3wxk8ijhp6qjnqp5zwifhhn";
            }) {});

            pact = addBuildDepend (self.callCabal2nix "pact" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "pact";
              rev = "ac0f72ed48f6e17dadedd76ee46e87c58de9a3f4";
              sha256 = "0y1c0kvsvhc5akgsyi5sspinjln37gaprbm54wh8s9vfysxq3b7m";
            }) {}) pkgs.z3;

            #pact-persist = self.callCabal2nix "pact-persist" (builtins.fetchGit {
            #  url = "ssh://git@github.com/kadena-io/pact-persist.git";
              # ref = "pact-2.4.x-upgrade";
              # This rev must be on the above branch ref
              # rev = "d0657343da4347637e9419096e324edf66a7c543";
              # Uncomment when nix and mysql branch merged into master.
              # rev = "1db11ffbc806b2e75b63ff64a7fcf6b29f4f073d"
              # ref = "mysql-nix-merge";

            pact-persist = self.callCabal2nix "pact-persist" (builtins.fetchGit {
              url = "ssh://git@github.com/kadena-io/pact-persist.git";
              rev = "289864150fce306767ad4865e61f96a5c81f308e";
              #sha256 = "0000000000000000000000000000000000000000000000000000";
            }) {};

            sbv = self.callCabal2nix "sbv" (pkgs.fetchFromGitHub {
              owner = "LeventErkok";
              repo = "sbv";
              rev = "3dc60340634c82f39f6c5dca2b3859d10925cfdf";
              sha256 = "18xcxg1h19zx6gdzk3dfs87447k3xjqn40raghjz53bg5k8cdc31";
            }) {};

            hdbc-odbc = self.callCabal2nix "hdbc-odbc" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "hdbc-odbc";
              rev = "79ffd1f5060d2c8b5cbdfd4eba8ae6414372d6b7";
              sha256 = "0000000000000000000000000000000000000000000000000000";
            }) {};

            ekg-prometheus-adapter = self.callCabal2nix "ekg-prometheus-adapter" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "ekg-prometheus-adapter";
              rev = "bd93dd5596d626b121f567bb24c0741fa0c8ccdd";
              sha256 = "0000000000000000000000000000000000000000000000000000";
            }) {};

            ridley = self.callCabal2nix "ridley" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "ridley";
              #subDir= "ridley";
              rev = "d523e11fb7c98870a9ace52461e756227ca75cd3";
              sha256 = "0x15cg95xj7133l18ivc0znfy31kvwnggi6jkjqbp64k68f9n6h7";
            }) {};

            # dontCheck is here because a couple tests were failing
            statistics = dontCheck (self.callCabal2nix "statistics" (pkgs.fetchFromGitHub {
              owner = "bos";
              repo = "statistics";
              rev = "1ed1f2844c5a2209f5ea72e60df7d14d3bb7ac1a";
              sha256 = "1jjmdhfn198pfl3k5c4826xddskqkfsxyw6l5nmwrc8ibhhnxl7p";
            }) {});

            thyme = dontCheck (self.callCabal2nix "thyme" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "thyme";
              rev = "6ee9fcb026ebdb49b810802a981d166680d867c9";
              sha256 = "09fcf896bs6i71qhj5w6qbwllkv3gywnn5wfsdrcm0w1y6h8i88f";
            }) {});

            # weeder = self.callHackage "weeder" "1.0.5" {};
            weeder = self.callCabal2nix "weeder" (pkgs.fetchFromGitHub {
              owner = "ndmitchell";
              repo = "weeder";
              rev = "56b46fe97782e86198f31c574ac73c8c966fee05";
              sha256 = "005ks2xjkbypq318jd0s4896b9wa5qg3jf8a1qgd4imb4fkm3yh7";
            }) {};
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

    toolOverrides = ghc: super: {
      z3 = pkgs.z3;
      stack = pkgs.stack;
    };
  })
