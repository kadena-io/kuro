{ pactRef ? "58bb39d891ddfdb0b9cf2f9bb7fb83342be9dfcf"
, pactSha ? "0qypr17xxx2djyq6ihrya8nywib78am2aikadh9bhhdxsbghn30c"
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
