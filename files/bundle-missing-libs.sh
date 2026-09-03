#!/usr/bin/env bash
# Copy into <prefix>/lib every shared library that the host cannot resolve
# for <prefix>/bin/emacs, taking them from <bundle-dir> (the libraries the
# binary resolved to inside the build container).  Loops because a bundled
# library can itself pull in further libraries.
#
# usage: bundle-missing-libs.sh <prefix> <bundle-dir>
set -euo pipefail
shopt -s nullglob

prefix=$1
bundle=$2
libdir=$prefix/lib
mkdir -p "$libdir"

missing() {
    # ldd exits nonzero when any dependency is unresolved; that is the
    # case we are looking for, not an error.
    { ldd "$prefix/bin/emacs" "$libdir"/*.so* 2>/dev/null || true; } \
        | awk '/not found/ { print $1 }' | sort -u
}

copied=()
for _ in 1 2 3 4 5 6; do
    libs=$(missing)
    [ -z "$libs" ] && break
    for lib in $libs; do
        if [ ! -e "$bundle/$lib" ]; then
            echo "no $lib in $bundle" >&2
            exit 1
        fi
        cp -L "$bundle/$lib" "$libdir/"
        copied+=("$lib")
    done
done

echo "bundled: ${copied[*]:-none}"
left=$(missing)
if [ -n "$left" ]; then
    echo "still unresolved: $left" >&2
    exit 1
fi
