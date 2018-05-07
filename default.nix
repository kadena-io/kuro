{ rpRef ? "ea3c9a1536a987916502701fb6d319a880fdec96", rpSha ?  "0339ds5xa4ymc7xs8nzpa4mvm09lzscisdgpdfc6rykwhbgw9w2a" }:

let rp = (import <nixpkgs> {}).fetchFromGitHub {
           owner = "mightybyte";
           repo = "reflex-platform";
           rev = rpRef;
           sha256 = rpSha;
         };

in
  (import rp {}).project ({ pkgs, ... }: {
    name = "kadena-umbrella";
    overrides = self: super:
      let guardGhcjs = p: if self.ghc.isGhcjs or false then null else p;
       in {
            # QuickCheck = pkgs.haskell.lib.dontCheck (self.callHackage "QuickCheck" "2.11.3" {});
            # aeson = self.callHackage "aeson" "1.0.2.1" {};
            # cacophony requires cryptonite >= 0.22 but doesn't supply a lower bound
            cacophony = pkgs.haskell.lib.dontCheck (self.callHackage "cacophony" "0.8.0" {});
            cryptonite = self.callHackage "cryptonite" "0.23" {};

            haskeline = self.callHackage "haskeline" "0.7.4.2" {};
            katip = pkgs.haskell.lib.doJailbreak (self.callHackage "katip" "0.3.1.4" {});
            ridley = pkgs.haskell.lib.dontCheck (self.callHackage "ridley" "0.3.1.2" {});

            # Version 1.6.4, needed by weeder, not in callHackage yet
            extra = pkgs.haskell.lib.dontCheck (self.callCabal2nix "extra" (pkgs.fetchFromGitHub {
              owner = "ndmitchell";
              repo = "extra";
              rev = "4064bfa7e48a7f1b79f791560d51dbefed879219";
              sha256 = "1p7rc5m70rkm1ma8gnihfwyxysr0n3wxk8ijhp6qjnqp5zwifhhn";
            }) {});

            thyme = pkgs.haskell.lib.dontCheck (self.callCabal2nix "thyme" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "thyme";
              rev = "6ee9fcb026ebdb49b810802a981d166680d867c9";
              sha256 = "09fcf896bs6i71qhj5w6qbwllkv3gywnn5wfsdrcm0w1y6h8i88f";
            }) {});

            # Old version because the kadena stack.yaml hasn't been updated in awhile
            # TODO Get rid of doJailbreak and dontCheck
            pact = pkgs.haskell.lib.doJailbreak (pkgs.haskell.lib.dontCheck (self.callCabal2nix "pact" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "pact";
              rev = "d1f2892bc739c1f8fb26b59b4e7528a592d5d12d";
              sha256 = "1j8k7vh2iz0r44a5r1h94p6ajg96hi1sn8wsclvv5mszwfcqcmh5";
            }) {}));
            # pact = pkgs.haskell.lib.dontCheck (self.callCabal2nix "pact" ../pact {});
            pact-persist = pkgs.haskell.lib.doJailbreak (self.callCabal2nix "pact-persist" (builtins.fetchGit {
              name = "pact-persist";
              url = ssh://git@github.com/kadena-io/pact-persist.git;
              rev = "2a4b1d333dea669038f10f30ab9b64aab2afd6b0";
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
      # pact = ../pact;
      # pact = pkgs.fetchFromGitHub {
      #   owner = "kadena-io";
      #   repo = "pact";
      #   rev = "32a0b461a30ecd08b38a10155908a6969d2f42bc";
      #   sha256 = "1v2nddx90zxx1akmiy0j3z460qxgm53088pimzspma9hcjny61d9";
      # };

      kadena = ./.;
    };
    
    shells = {
      ghc = ["pact" "kadena"];
      # ghcjs = ["pact" "pact-ghcjs"];
    };
  
  })
