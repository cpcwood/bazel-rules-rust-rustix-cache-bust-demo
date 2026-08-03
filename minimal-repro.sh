#!/usr/bin/env bash
# Reproduces the mechanism with no Bazel involved: rustc folds its working
# directory into --emit=metadata output, and --remap-path-prefix removes it.
set -euo pipefail

# On macOS `mktemp -d` returns a path under the /var -> /private/var symlink,
# while rustc records the canonicalised working directory. A remap prefix built
# from the non-canonical path silently never matches, and the fix looks broken.
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

SHORT="$TMP/s"
LONG="$TMP/a-deliberately-much-longer-directory-name"
mkdir -p "$SHORT" "$LONG"

# Source arrives on stdin, exactly as rustix's build.rs feeds its probe, so no
# source path reaches rustc. The working directory is its only path input.
SRC='pub fn f(x: &core::num::NonZeroI32) -> i32 { x.get() }'

emit() { # dir, output-name, extra-args...
  local dir="$1" out="$2"; shift 2
  ( cd "$dir" && printf '%s\n' "$SRC" \
      | rustc --crate-type=rlib --emit=metadata "$@" -o "$out" - )
}

hash_of() { sha256sum "$1" | cut -d' ' -f1; }

for d in "$SHORT" "$LONG"; do
  emit "$d" probe_unpatched
  emit "$d" probe_patched --remap-path-prefix="$d=."
done

u_short="$(hash_of "$SHORT/probe_unpatched")"
u_long="$(hash_of "$LONG/probe_unpatched")"
p_short="$(hash_of "$SHORT/probe_patched")"
p_long="$(hash_of "$LONG/probe_patched")"

printf '\nwithout --remap-path-prefix\n  %s  (short path)\n  %s  (long path)\n' "$u_short" "$u_long"
printf '\nwith    --remap-path-prefix=$PWD=.\n  %s  (short path)\n  %s  (long path)\n\n' "$p_short" "$p_long"

rc=0
if [ "$u_short" = "$u_long" ]; then
  echo "UNEXPECTED: unpatched hashes match; the mechanism did not reproduce" >&2
  rc=1
else
  echo "OK   unpatched output differs by path"
fi
if [ "$p_short" != "$p_long" ]; then
  echo "UNEXPECTED: patched hashes still differ; the flag did not fix it" >&2
  rc=1
else
  echo "OK   patched output is identical across paths"
fi
exit "$rc"
