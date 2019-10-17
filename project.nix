{ pactRef ? "404013a367bedc724578b79d7919d178e8691ff9"
, pactSha ? "0zgqr9v670fjdrljjh6177gqnhg8jcxfcrjr2lxf3l15jrrz3kdh"
}:
let

pactSrc = builtins.fetchTarball {
  url = "https://github.com/kadena-io/pact/archive/${pactRef}.tar.gz";
  sha256 = pactSha;
};

in
  (import pactSrc {}).rp.project ({ pkgs, ... }:
let

gitignore = pkgs.callPackage (pkgs.fetchFromGitHub {
  owner = "siers";
  repo = "nix-gitignore";
  rev = "addd0c9665ddb28e4dd2067dd50a7d4e135fbb29";
  sha256 = "07ngzpvq686jkwkycqg0ary6c07nxhnfxlg76mlm1zv12a5d5x0i";
}) {};

in {
    name = "kadena-umbrella";
    overrides = import ./overrides.nix pactSrc pkgs;

    packages = {
      kadena = gitignore.gitignoreSource [".git" ".gitlab-ci.yml" "CHANGELOG.md" "README.md"] ./.;
    };

    shellToolOverrides = ghc: super: {
      z3 = pkgs.z3;
      stack = pkgs.stack;
    };

    shells = {
      ghc = ["kadena"];
    };
  })
