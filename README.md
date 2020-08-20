# Kuro

Kuro is Kadena's high-performance permissioned blockchain, based upon the ScalableBFT consensus algorithm
by Will Martino. Kuro also features _counterparty confidentiality_ leveraging the Noise protocol,
and runs the Pact smart contract language.

For more information:
- [Pact](https://github.com/kadena-io/pact)
- [ScalableBFT whitepaper](https://d31d887a-c1e0-47c2-aa51-c69f9f998b07.filesusr.com/ugd/86a16f_aeb9004965c34efd9c48993c4e63a9bb.pdf)
- [Confidentiality whitepaper](https://d31d887a-c1e0-47c2-aa51-c69f9f998b07.filesusr.com/ugd/86a16f_29bcbfd45f9e48139e6db4e5a0fbf5f1.pdf)

## Beta and AWS Build Instructions

### Manual Part

1. Create a `submodules` directory
2. Inside the `submodule/` directory, git clone all packages found in `stack.yaml`
3. Checkout the correct version of everything found in the `stack.yaml` packages section (example):

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

4. Create a stack-docker.yaml file as follows:

```
> cp stack.yaml stack-docker.yaml

# Edit all of these...
- location:
    git: git@github.com:kadena-io/thyme.git
    commit: 6ee9fcb026ebdb49b810802a981d166680d867c9
  extra-dep: true
# ...to be these
- location: submodules/thyme
  extra-dep: true
```

NB: we do this because it's easier than fighting with either submodules or getting docker to be able to clone on it's own

### Automated Part
Install `npm`. On Mac OS, you can run `brew install node`, which installs NodeJS and npm.

Make sure that `kadena` is building and all tests are passing.

Start Docker with a memory allowance of at least 4 GB.

Run `./scripts/build-beta-distro.sh beta` to build kadena-beta, or
run `./scripts/build-beta-distro.sh aws` to build kadena-aws.
Then go get a coffee because it'll take a while.

When it's done, the script outputs the file `kadena-beta-\<version number\>.tgz`
or `kadena-aws-\<version number\>.tgz`. If the file is missing a version number,
add it to .tgz file created.
