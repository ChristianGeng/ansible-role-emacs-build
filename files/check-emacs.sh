#!/usr/bin/env bash
# Host-side smoke test of a built Emacs prefix: all libraries resolve,
# the binary runs, the compiled-in features are there, and native
# compilation works on this host (libgccjit + gcc driver).
#
# usage: check-emacs.sh <prefix>
set -uo pipefail

prefix=$1
emacs=$prefix/bin/emacs
rc=0

echo "== unresolved libraries"
if ldd "$emacs" | grep -q 'not found'; then
    ldd "$emacs" | grep 'not found'; rc=1
else
    echo none
fi

echo "== version"
"$emacs" --version | head -1 || rc=1

echo "== features"
"$emacs" --batch --eval '
(progn
  (dolist (f (list (cons "native-comp" (and (fboundp (quote native-comp-available-p))
                                            (native-comp-available-p)))
                   (cons "tree-sitter" (and (fboundp (quote treesit-available-p))
                                            (treesit-available-p)))
                   (cons "sqlite" (and (fboundp (quote sqlite-available-p))
                                       (sqlite-available-p)))
                   (cons "json" (fboundp (quote json-parse-string)))
                   (cons "gnutls" (gnutls-available-p))
                   (cons "modules" (fboundp (quote module-load)))
                   (cons "xml" (fboundp (quote libxml-parse-html-region)))))
    (princ (format "%-12s %s\n" (car f) (if (cdr f) "yes" "NO"))))
  (princ (format "%-12s %s\n" "features" system-configuration-features)))' || rc=1

echo "== native compile on this host"
"$emacs" --batch --eval '
(progn
  (defun emacs-build-probe (x) (* 2 x))
  (let ((fn (native-compile (quote emacs-build-probe))))
    (if (and (subr-native-elisp-p fn) (= (funcall fn 21) 42))
        (princ "native-compile works\n")
      (error "native-compile returned %S" fn))))' || rc=1

echo "== tree-sitter library"
"$emacs" --batch --eval '(princ (format "abi %s..%s\n" (treesit-library-abi-version t) (treesit-library-abi-version)))' || rc=1

exit $rc
