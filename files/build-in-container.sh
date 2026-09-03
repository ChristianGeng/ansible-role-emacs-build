#!/usr/bin/env bash
# Runs INSIDE the toolchain container, as the calling host user, with the
# work dir and the install prefix bind-mounted at their host paths.
# Downloads, configures, builds and installs Emacs, then collects every
# shared library the binary resolves to into <work>/bundle.
#
# Environment (set by the role):
#   EMACS_VERSION EMACS_TARBALL_URL EMACS_PREFIX EMACS_JOBS
#   EMACS_CONFIGURE_ARGS (space separated) EMACS_CFLAGS EMACS_WORK
set -euo pipefail

cd "$EMACS_WORK"
src=$EMACS_WORK/emacs-$EMACS_VERSION

if [ ! -f "$src/configure" ]; then
    echo "== download $EMACS_TARBALL_URL"
    curl -fsSL "$EMACS_TARBALL_URL" | tar -xJ
fi
cd "$src"

echo "== configure --prefix=$EMACS_PREFIX"
# shellcheck disable=SC2086  # the args are meant to split
./configure --prefix="$EMACS_PREFIX" $EMACS_CONFIGURE_ARGS \
    CFLAGS="$EMACS_CFLAGS" \
    LDFLAGS="-Wl,-rpath,$EMACS_PREFIX/lib" > "$EMACS_WORK/configure.log"

echo "== make -j$EMACS_JOBS"
make -j"$EMACS_JOBS" > "$EMACS_WORK/make.log" 2>&1
echo "== make install"
make install > "$EMACS_WORK/install.log" 2>&1

echo "== collect libraries"
rm -rf "$EMACS_WORK/bundle" && mkdir -p "$EMACS_WORK/bundle"
ldd "$EMACS_PREFIX/bin/emacs" \
    | awk '$2 == "=>" && $3 ~ /^\// { print $3 }' \
    | xargs -I{} cp -L {} "$EMACS_WORK/bundle/"
ls "$EMACS_WORK/bundle" | wc -l | xargs echo "   candidate libraries:"
