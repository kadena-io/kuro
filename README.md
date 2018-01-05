

# Beta Build Instructions

### Manual Part

1. Create a submodules directory
2. Checkout the correct version of everything found in `stack.yaml` packages section (example):

```
# stack.yaml
packages:
- '.'
- location:
    git: git@bitbucket.org:spopejoy/pact.git
    commit: 41d0cae570af056a06868298546a806da2d2eadc
  extra-dep: true
- location:
    git: git@bitbucket.org:spopejoy/pact-persist.git
    commit: b9c627663d402ec7d2fe9665872e9c01ab8de07a
  extra-dep: true
- location:
    git: https://github.com/abbradar/hdbc-odbc.git
    commit: 79ffd1f5060d2c8b5cbdfd4eba8ae6414372d6b7
  extra-dep: true
- location:
    git: git@github.com:kadena-io/thyme.git
    commit: 6ee9fcb026ebdb49b810802a981d166680d867c9
  extra-dep: true

## So...
cd submodules/pact
git fetch && git checkout 41d0cae570af056a06868298546a806da2d2eadc
cd ../hdbc-odbc
git fetch && git checkout 79ffd1f5060d2c8b5cbdfd4eba8ae6414372d6b7
cd ../pact-persist
git fetch && git checkout b9c627663d402ec7d2fe9665872e9c01ab8de07a
cd ../thyme
git fetch && git checkout 6ee9fcb026ebdb49b810802a981d166680d867c9
```

NB: we do this because it's easier than fighting with either submodules or getting docker to be able to clone on it's own

### Automated Part

Start Docker, run `./scripts/build-beta-distro.sh`, go get a coffee because it'll take a while.

When it's done, add a version number the kadena-beta.tgz that's created
