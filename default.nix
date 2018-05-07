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

            criterion = pkgs.haskell.lib.dontCheck (self.callCabal2nix "criterion" (pkgs.fetchFromGitHub {
              owner = "bos";
              repo = "criterion";
              rev = "5a704392b670c189475649c32d05eeca9370d340";
              sha256 = "1kp0l78l14w0mmva1gs9g30zdfjx4jkl5avl6a3vbww3q50if8pv";
            }) {});

            # Version 1.6.4, needed by weeder, not in callHackage yet
            extra = pkgs.haskell.lib.dontCheck (self.callCabal2nix "extra" (pkgs.fetchFromGitHub {
              owner = "ndmitchell";
              repo = "extra";
              rev = "4064bfa7e48a7f1b79f791560d51dbefed879219";
              sha256 = "1p7rc5m70rkm1ma8gnihfwyxysr0n3wxk8ijhp6qjnqp5zwifhhn";
            }) {});

            pact = self.callCabal2nix "pact" (pkgs.fetchFromGitHub {
              owner = "kadena-io";
              repo = "pact";
              rev = "242410f98c0be90cb8c8eb13e6615349bcd9c9d0";
              sha256 = "0a8qghdj7cxlm0v2i07f3l5n4x80my4jifswvxih0av0fqb225bg";
            }) {};

            pact-persist = self.callCabal2nix "pact-persist" (builtins.fetchGit {
              url = "ssh://git@github.com/kadena-io/pact-persist.git";
              ref = "pact-2.3.8-upgrade";
              # This rev must be on the above branch ref
              rev = "96f4b110a177cb1876632852a498c20bc8a3878c";
            }) {};

            # dontCheck is here because a couple tests were failing
            statistics = pkgs.haskell.lib.dontCheck (self.callCabal2nix "statistics" (pkgs.fetchFromGitHub {
              owner = "bos";
              repo = "statistics";
              rev = "1ed1f2844c5a2209f5ea72e60df7d14d3bb7ac1a";
              sha256 = "1jjmdhfn198pfl3k5c4826xddskqkfsxyw6l5nmwrc8ibhhnxl7p";
            }) {});

            thyme = pkgs.haskell.lib.dontCheck (self.callCabal2nix "thyme" (pkgs.fetchFromGitHub {
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
      kadena = ./.;
    };
    
    shells = {
      ghc = ["kadena"];
    };
  
  })
