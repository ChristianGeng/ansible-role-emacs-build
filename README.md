# ansible-role-emacs-build

Build GNU Emacs from source inside Docker and leave a **natively
runnable** install on the host: no root, no apt packages on the host, and
nothing left behind in the Docker daemon afterwards.

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
