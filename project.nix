{ pactRef ? "26d26d939f578e103097f3370806573f4f41aaeb"
, pactSha ? "1nkrjw6wlf4gc0v1fa3vl8w1m3gqk31mpx0xlvp7ad3k4rkaqnz7"
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
