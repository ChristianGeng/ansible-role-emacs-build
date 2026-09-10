# ansible-role-emacs-build

[![CI](https://github.com/ChristianGeng/ansible-role-emacs-build/actions/workflows/ci.yml/badge.svg)](https://github.com/ChristianGeng/ansible-role-emacs-build/actions/workflows/ci.yml)

Build GNU Emacs from source inside Docker and leave a **natively
runnable** install on the host: no root, no apt packages on the host, and
nothing left behind in the Docker daemon afterwards.

Or skip the compile entirely and install the tarball CI already built:
[Installing a prebuilt build](#installing-a-prebuilt-build-no-compile).

Galaxy: `christiangeng.emacs_build`.

## When you need this

For **frozen distributions** whose packaged Emacs is too old to run a
modern config: Ubuntu LTS, Debian stable, and similar. **Rolling
releases** (Arch, Debian unstable) already ship a current Emacs and do
not need this role. The base image is the host's own distribution
release, so glibc matches and the binary runs natively outside the
container.

## How it works

1. **Pre-flight.** Refuses to start unless the filesystem holding
   Docker's data root has `emacs_min_free_gb_docker` GB free (default 4)
   and the one holding `emacs_work_dir` has `emacs_min_free_gb_work` GB
   (default 6).
2. **Toolchain image.** `templates/Dockerfile.j2` is rendered with the
   host's own distribution release as base (`ubuntu:22.04` on a Jammy
   host, so glibc matches), the Emacs build dependencies, and tree-sitter
   built from source.  It is built on a dedicated buildx builder
   (`docker-container` driver) so its cache can be dropped as a unit
   without touching anything else on a shared daemon.  About 1 GB.
3. **Compile.** `files/build-in-container.sh` runs in a container from
   that image as the calling user, with `emacs_work_dir` and the parent
   of `emacs_prefix` bind-mounted at their host paths.  Sources and
   object files therefore live on the host disk of your choice (default
   under `~/local/build`, i.e. `$HOME`'s filesystem), and `make install`
   writes straight to `~/local/emacs-<version>`, the very path the
   binary was configured for.  Native compilation is ahead-of-time.
4. **Bundle.** `files/bundle-missing-libs.sh` runs `ldd` on the host and
   copies only the libraries the host cannot resolve (on Jammy:
   `libgccjit.so.0`, `libtree-sitter.so.0`, `libgif.so.7`,
   `libwebpdemux.so.2`) into `<prefix>/lib`, where the binary's rpath
   finds them.
5. **Verify.** `files/check-emacs.sh`: nothing unresolved, the features
   are present, and a live `native-compile` round-trip on the host.
6. **Link.** `emacs-<version>` and `emacsclient-<version>` into
   `~/local/bin`; with `emacs_set_default: true` also the unversioned
   `emacs` and `emacsclient`.
7. **Cleanup** (`emacs_cleanup: true`, default): remove the toolchain
   image, the builder and its cache, the buildkit helper image, and the
   whole work dir.  The daemon and the disk end up as they were found; a
   re-run compiles from scratch again (~25 min on 16 cores).

## Requirements

- Docker usable by the current user without sudo.  The role calls the
  `docker` CLI rather than the Python SDK on purpose: on hosts where
  `/usr/bin/docker` is setgid `docker` and the user is not in the group,
  only the CLI can open the socket.
- For runtime native compilation on the host: `binutils` and the gcc
  support directory matching `emacs_gcc_version`
  (`/usr/lib/gcc/x86_64-linux-gnu/12` on Jammy).  Ubuntu images with
  `build-essential` have these.
- Only `ansible.builtin` modules; `ansible-core` is enough.

## Variables

See `defaults/main.yml`.  The ones you will touch:

| variable                 | default                                     |
|--------------------------|---------------------------------------------|
| `emacs_version`          | `30.2`                                      |
| `emacs_prefix`           | `~/local/emacs-{{ emacs_version }}`         |
| `emacs_bin_dir`          | `~/local/bin`                               |
| `emacs_work_dir`         | `~/local/build/emacs-build-<ver>/work`      |
| `emacs_base_image`       | `ubuntu:{{ ansible_distribution_version }}` |
| `emacs_configure_args`   | gtk3, cairo, tree-sitter, sqlite, aot native comp |
| `emacs_set_default`      | `false`                                     |
| `emacs_cleanup`          | `true`                                      |
| `emacs_min_free_gb_*`    | `4` (Docker disk), `6` (work disk)          |

## Usage

```sh
ansible-playbook emacs-build.yml
ansible-playbook emacs-build.yml -e emacs_version=31.1
ansible-playbook emacs-build.yml -e emacs_set_default=true --tags link   # relink only, no rebuild
```

Then point Doom at it.  Doom keys its package build on the Emacs version
(`.local/straight/build-30.2`), so the install for the previous version
stays intact.  On the version change Doom asks whether to rebuild all
packages; answer yes, or pass `-!` to skip the prompt.

```sh
EMACS=~/local/bin/emacs-30.2 ~/doom-emacs/bin/doom sync
~/local/bin/emacs-30.2 --with-profile doom -nw
```

## Installing a prebuilt build (no compile)

Every full CI run uploads the finished install tree, so a box that only
has to *run* Emacs never has to build it.  The artifact is
`emacs-<emacs>-ubuntu-<release>-x86_64.tar.zst` with a `.sha256` beside
it.

CI builds **one tarball per Emacs version per Ubuntu LTS** — a matrix of
30.2 and 31.1 against 22.04, 24.04 and 26.04 — so substitute both numbers
into the filenames below.  A release carries every cell side by side.

**Match the tarball to your distribution.**  The binary links against the
glibc of the release it was built on, so a 24.04 tarball will not run on
22.04.  Take the one whose `ubuntu-<release>` is your own; newer than your
own will not work, older generally will but is not tested.

**The tree is not relocatable.**  Emacs bakes the configure prefix into
the binary — lisp dir, native-lisp dir, rpath — so it only works at the
path it was configured for.  CI therefore builds at `/opt/emacs-<version>`
rather than the role's `~/local` default, precisely because `/opt` exists
on every box and is the same path everywhere.  Extract it anywhere else
and Emacs will not find its own lisp directory.

The target needs x86_64 and, for runtime native compilation, `binutils`
plus the gcc support directory that matches the release the tarball was
built on — `/usr/lib/gcc/x86_64-linux-gnu/12` on 22.04,
`/usr/lib/gcc/x86_64-linux-gnu/14` on 24.04 and 26.04, because that is
where each release's `libgccjit0` comes from.  Everything else the binary
needs that the distribution does not ship is bundled inside
`/opt/emacs-<version>/lib`.

### Download

**From a workflow run.**  Works for every full build, needs
`gh auth login` and read access to the repo.  This is the route that is
always available:

```sh
gh run download --repo ChristianGeng/ansible-role-emacs-build \
    --name emacs-31.1-ubuntu-22.04 --dir .
```

There is one artifact per cell — `emacs-30.2-ubuntu-22.04`,
`emacs-31.1-ubuntu-24.04` and so on — so swap the `--name`, or drop it to
fetch every cell from that run at once.  Artifacts expire after 90 days.
`--name` picks the newest matching artifact from the most recent run that
has one; pass a run id as the first argument to pin a specific build.

**From a release.**  No auth, no `gh`, and the URL is stable — but it
only resolves once a `v*` tag has been pushed *and* its `full-build` job
has finished uploading.  `releases/latest/download/...` returns 404 while
the repo has no published release, so check
[the releases page](https://github.com/ChristianGeng/ansible-role-emacs-build/releases)
first:

```sh
emacs=31.1
release=$(. /etc/os-release && echo "$VERSION_ID")   # 22.04, 24.04, 26.04
tarball=emacs-$emacs-ubuntu-$release-x86_64.tar.zst

base=https://github.com/ChristianGeng/ansible-role-emacs-build/releases/latest/download
curl -fLO "$base/$tarball"
curl -fLO "$base/$tarball.sha256"
```

`latest` also ignores pre-releases, so a pre-release tag will not make
that URL resolve.

### Verify and install

Continuing with the `$emacs` and `$tarball` set above:

```sh
sha256sum -c "$tarball.sha256"
sudo tar --zstd --no-same-owner -xf "$tarball" -C /opt
mkdir -p ~/local/bin
ln -sfn "/opt/emacs-$emacs/bin/emacs"       ~/local/bin/emacs-$emacs
ln -sfn "/opt/emacs-$emacs/bin/emacsclient" ~/local/bin/emacsclient-$emacs
```

`--no-same-owner` matters: the archive carries the CI runner's uid, and
`tar` as root would otherwise restore it, leaving `/opt/emacs-<version>`
owned by whatever local account happens to hold uid 1001.

`sudo` is needed only to write into `/opt`.  Nothing is registered with
the package manager, no apt packages are installed, and removing the
build is `sudo rm -rf /opt/emacs-<version>` plus the two symlinks.
Different Emacs versions install side by side, since the prefix carries
the version.

If you cannot write to `/opt` on the target at all, the prebuilt tarball
is not an option — the prefix is baked in, so there is no unprivileged
path that works.  Run the role instead; its default prefix is
`~/local/emacs-<version>` and needs no root.

### Check it

```sh
~/local/bin/emacs-$emacs --version
~/local/bin/emacs-$emacs --batch --eval \
    '(princ (format "native-comp %s treesit %s\n" (native-comp-available-p) (treesit-available-p)))'
```

## CI

`.github/workflows/ci.yml`, tiered because the cost difference is
enormous:

| job | when | cost |
|------|------|------|
| `lint` — yamllint, ansible-lint, playbook syntax check | every push and PR | seconds |
| `toolchain` — render the Dockerfile and build the image, stopping before `configure`, per distribution | every push and PR | a few minutes, in parallel |
| `full-build` — compile, verify, package, upload, once per cell | weekly, on a `v*` tag, on manual dispatch, or on a push whose commit message contains `[full-build]` | ~20 min per cell, in parallel |
| `release` — collect every cell's tarball and attach it | on a `v*` tag | seconds |

The `toolchain` tier is `--tags toolchain,cleanup`, which exercises base
image resolution and the apt build-dep list — the parts most likely to rot
— without paying for the compile.  Run it locally the same way:

```sh
ansible-playbook tests/test.yml --tags toolchain,cleanup
```

`full-build` is a matrix of Emacs version against Ubuntu LTS release:
30.2 and 31.1 against 22.04, 24.04 and 26.04, six cells in parallel with
`fail-fast: false` so a regression in one cell cannot cancel the rest.
Both lists live only in the `matrix` block; a manual dispatch can narrow
either axis:

```sh
gh workflow run CI -f emacs_versions='["31.1"]' -f ubuntu_versions='["24.04"]'
```

Two constraints the matrix has to respect, both easy to get wrong:

- **The runner is always the same release as the base image.**  The role
  compiles inside the container but resolves libraries and runs the
  native-compile probe on the *host*, so a binary built against noble's
  glibc cannot be verified on a jammy runner.  `runs-on` is derived from
  the same matrix value as `emacs_base_image`.
- **`emacs_gcc_version` follows the distribution.**  `libgccjit0` is built
  from gcc-12 on jammy but gcc-14 on noble and resolute.  Mismatch it and
  the image builds fine, then `check-emacs.sh` fails on the host at the
  native-compile probe.  `matrix.include` keys the gcc version on the
  release so the two cannot drift apart.

Note that `emacs_version` in `defaults/main.yml` is a *separate* decision
from what CI builds — it is the version consumers get, and moving it has
to be paired with the guard in `dotfiles/provision/personal-bootstrap.sh`,
which looks for `~/local/bin/emacs-<version>` without fetching the role.

`release` is its own job rather than a step in the matrix on purpose: two
matrix jobs both creating the release for one tag race each other.

`meta/main.yml` lists exactly the releases CI proves and nothing more.
Debian is still absent for that reason: the role has no Ubuntu-specific
logic and bookworm ought to work, but nothing exercises it.

## Idempotence

- Directories, the Dockerfile render and the symlinks are ordinary
  idempotent tasks.
- The install tree at the prefix is removed and re-created on every run
  (`emacs_clean_install: true`), since a merge over an old tree could
  leave stale files behind.
- With `emacs_cleanup: true` every run compiles from scratch.  The
  provisioning layer (dotfiles `provision/personal-bootstrap.sh`) is what
  makes it run once: it skips the role when
  `~/local/bin/emacs-<version>` already runs unless `EMACS_BUILD=1`.
