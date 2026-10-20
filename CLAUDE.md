# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb for crane, the go-containerregistry CLI that copies, tags and inspects container images directly in their registries, without a Docker daemon. The orb installs a checksum-verified crane and wraps its most used commands.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh tests/*.sh

# Tests (offline)
for t in tests/*_test.sh; do bash "$t" || break; done

# Generate SHA-512 checksums (linux amd64 + arm64) for a new crane version
./src/scripts/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/` - One command per crane subcommand, named after it
  - `install.yml` - Installs crane with caching and checksum verification
  - `login.yml` / `logout.yml` - `crane auth login` / `crane auth logout`
  - `copy.yml` - `crane copy`
  - `digest.yml` - `crane digest --full-ref`, exports the digest and the reference by digest (`digest_env_var`/`digest_ref_env_var`, defaults `CRANE_DIGEST`/`CRANE_DIGEST_REF`)
  - `tag.yml` - `crane tag`, once per tag in `tags`
- `scripts/` - Shell implementations, one per command, included with `<< include(scripts/...) >>`
- `scripts/lib/crane.sh` - Helpers shared by the command scripts. Each command passes it to its step as `SCRIPT_CRANE_LIB: << include(scripts/lib/crane.sh) >>`, and the script `eval`s it after checking it is set. It only defines functions and has no `set` line.
- `examples/` - Usage examples, pinned to the orb's current version

### Key Implementation Details

**`scripts/install.sh`**: Installs the linux amd64 or arm64 crane build (from `uname -m`) from the go-containerregistry GitHub releases with SHA-512 checksum verification. The release archive (`go-containerregistry_Linux_<x86_64|arm64>.tar.gz`) also holds gcrane and krane; only `crane` is installed. It follows the layout every juburr orb's install.sh shares: a tool definition, a shared install logic block that must stay identical across the orbs, and a checksum table keyed `"<version>/<arch>"` holding the SHA-512 of the `crane` binary inside the archive. Three verification modes: `false`, `known_versions`, `strict` (default, fails before downloading an unlisted version). `tests/install_test.sh` is the install contract test shared by the orbs, and `scripts/cache_key.sh` is shared too; never edit the shared parts in one orb only.

**`scripts/install_hash.sh`**: Prints new checksum table entries. Its `verify_upstream` checks the archive against the release's SLSA provenance (`multiple.intoto.jsonl`) with `slsa-verifier verify-artifact --print-provenance`, for `github.com/google/go-containerregistry` at tag `v<version>`, then requires the verified provenance to list the archive's name with its SHA-256 (with `jq`), since one provenance covers every platform's archive and slsa-verifier matches by digest only. It then checks the archive against `checksums.txt`. The provenance signs the archives themselves, not `checksums.txt`. Six releases were published without provenance; they are listed in `CRANE_RELEASES_WITHOUT_PROVENANCE` and checked against `checksums.txt` alone, and any other release without provenance fails, whatever `checksums.txt` and `-c` say. The table starts at 0.13.0, the first release with provenance; 0.15.0, 0.16.0 and 0.20.8 were tagged but never published.

**`scripts/lib/crane.sh`**:
- `crane_subst` expands environment variables by piping the value to `circleci env subst` on stdin, and uses the value as is without the CLI (local runs).
- `crane_words` splits `tags` and `extra_args` like shell words with `split_shell_words`, the same parser container-ops-orb and oras-orb use: quotes keep spaces, and nothing is expanded or executed. A `$(...)`, backtick or shell operator outside quotes fails the step instead of reaching crane.
- `crane_global_args` turns `platform` and `insecure` into crane's global `--platform` and `--insecure` flags.
- `crane_export` writes `export NAME=value` to `$BASH_ENV` with `printf 'export %s=%q\n'`.

**`scripts/login.sh`**: Reads the credentials through indirect expansion of the variable names passed as `username` and `password`, turns xtrace off first, and pipes the password to `crane auth login --password-stdin` with `printf`. Both must be set: without a username, crane stores an auth entry that crane 0.14.0 and later reject when they read the Docker config, which breaks every later crane command. crane does not contact the registry at login, so wrong credentials only fail the first command that uses them.

**`scripts/logout.sh`**: `crane auth logout` exists from crane 0.15.1; on older crane the step fails with an `ERROR:` naming that version.

**`scripts/digest.sh`**: Runs `crane digest --full-ref` once and derives the digest from the reference, so the two exported values always describe the same manifest. Output that isn't `<repository>@sha256:<64 hex>` fails the step.

**`scripts/tag.sh`**: Validates every tag (`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`) before running `crane tag` for any of them, then stops at the first failure.

Every crane call ends its options with `--`, so a reference that starts with `-` is never read as a flag.

### CI Pipeline (`.circleci/`)

- `config.yml` - Setup workflow: `test-install` (install contract), `test-env-subst` (env subst and shell conventions), `test-commands` (`tests/login_test.sh` and `tests/commands_test.sh` against a stand-in crane), orb-tools lint, pack and review, shellcheck.
- `test-deploy.yml` - `command-test`, `checksum-test` (the unlisted 0.12.0 fails closed; `known_versions` installs it), `arm64-test` (Arm machine, second install from cache), and `registry-test`, a matrix over crane 0.15.1 (the oldest with `auth logout`) and the default version. It copies `cgr.dev/chainguard/static:latest`, pinned to the digest it reads first, into a `registry:2` with htpasswd auth on a machine executor, whole and as linux/arm64, and checks the exported digests against the source's and the registry's, the tags, and that the registry refuses crane after `logout`. The source comes from the registry that publishes it, not mirror.gcr.io: that pull-through cache can be missing the layers of platforms few people pull, and failed the copy that way. Publishing runs on `v*` tags.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `crane_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace; `login.sh` runs `set +o xtrace` with a one-line comment.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them.
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. The tests run the scripts with the bash first on the `PATH`, so put a bash 4.3 there to check this locally.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_CRANE_LIB}"`). Secrets never go on a command line, and curl that sends credentials or fetches trusted content uses `--fail` and `--proto '=https'`.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script (a second `trap ... EXIT` replaces the first).

## Naming

Command names are crane's own subcommands (`login`/`logout` for `crane auth login`/`logout`). Parameters that map onto one crane flag take its long name in snake_case (`platform`, `insecure`); positional arguments take crane's names for them (`source`/`destination` for copy's SRC/DST, `image`), except `login`/`logout`'s `[SERVER]`, which is `registry` as in oras-orb, helm-orb and container-ops-orb. Plumbing matches the other juburr orbs: credentials are `env_var_name` parameters named `username` and `password` (defaults `REGISTRY_USERNAME`/`REGISTRY_PASSWORD`, shared with container-ops-orb, helm-orb and oras-orb), variables a command writes are `<thing>_env_var`, and pass-through arguments are `extra_args`.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh tests/*.sh` to lint shell scripts
- Run every `tests/*_test.sh`
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml` to validate the orb structure
- For changes to a command, also run it against a real registry that requires a login, under crane 0.15.1 and the default version, as `registry-test` does
