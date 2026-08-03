#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$ROOT/work"

SHORT_WS="s"
LONG_WS="a-deliberately-much-longer-workspace-directory-name"
SHORT_OB="s"
LONG_OB="a-deliberately-much-longer-output-base-directory-name"

RC=0
note() { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  OK   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*" >&2; RC=1; }

# Shared repository cache: caches downloads only, never action outputs, so it
# cannot influence the result. Without it the toolchain is fetched four times.
# Overridable so CI can point it at a path it persists between runs.
REPO_CACHE="${PROVE_REPOSITORY_CACHE:-$WORK/repository_cache}"

materialise() { # mode ws_name -> workspace path on stdout
  local mode="$1" ws="$2" dest="$WORK/$mode/$2"
  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"
  cp -R "$ROOT/demo" "$dest"
  cp -R "$ROOT/patches" "$dest/patches"
  if [ "$mode" = "patched" ]; then
    cat >> "$dest/MODULE.bazel" <<'OVERRIDE'

single_version_override(
    module_name = "rules_rust",
    patch_strip = 1,
    patches = ["//patches:cargo_build_script_remap.patch"],
)
OVERRIDE
  fi
  printf '%s' "$dest"
}

ob_path() { # mode ws_name
  local ob="$SHORT_OB"
  [ "$2" = "$LONG_WS" ] && ob="$LONG_OB"
  printf '%s' "$WORK/ob/$1/$ob"
}

# Shut the server down and delete an output base. Bazel leaves output
# directories read-only (dr-xr-xr-x), so a plain rm -rf fails with "Permission
# denied" and silently strands gigabytes, invisible because errexit does not
# propagate into $(...) subshells.
discard_output_base() { # dest ob
  ( cd "$1" && bazel --output_base="$2" shutdown ) >/dev/null 2>&1 || true
  chmod -R u+w "$2" 2>/dev/null || true
  rm -rf "$2"
}

probe_hash() { # mode ws_name -> sha256 on stdout
  local mode="$1" ws="$2"
  local dest ob file sum bzl
  dest="$(materialise "$mode" "$ws")"
  ob="$(ob_path "$mode" "$ws")"
  # A prior run killed mid-build (CI timeout, SIGKILL) can leave a live server
  # and a read-only output base; go through the same hardened teardown.
  discard_output_base "$dest" "$ob"; mkdir -p "$ob"
  ( cd "$dest" && bazel --output_base="$ob" build //:myapp \
      --repository_cache="$REPO_CACHE" ) >"$WORK/$mode-$ws.log" 2>&1

  # A patched run that silently failed to apply the patch would show matching
  # hashes by luck, not by fix. Check the extracted rules_rust really carries
  # the flag before trusting anything downstream of it.
  if [ "$mode" = "patched" ]; then
    bzl="$(find "$ob/external" -name cargo_build_script.bzl -path '*cargo/private*' 2>/dev/null | head -1)"
    if [ -z "$bzl" ] || ! grep -q 'remap-path-prefix' "$bzl"; then
      echo "single_version_override did not apply the patch (checked: ${bzl:-none found})" >&2
      discard_output_base "$dest" "$ob"
      exit 1
    fi
  fi

  file="$(find "$ob/execroot/_main/bazel-out" -name rustix_test_can_compile -type f | head -1)"
  if [ -z "$file" ]; then
    echo "could not find rustix_test_can_compile under $ob" >&2
    discard_output_base "$dest" "$ob"
    exit 1
  fi
  sum="$(sha256sum "$file" | cut -d' ' -f1)"

  # Each output base holds its own Rust toolchain. Keeping eight of them alive
  # exhausts a CI runner's disk, and each idle bazel server holds RAM.
  discard_output_base "$dest" "$ob"

  printf '%s' "$sum"
}

mkdir -p "$WORK"

note "Phase 1: does the build-script probe output depend on the build path?"

u_short="$(probe_hash unpatched "$SHORT_WS")"
u_long="$(probe_hash unpatched "$LONG_WS")"
printf '  unpatched  %s  %s\n' "$u_short" "$SHORT_WS"
printf '  unpatched  %s  %s\n' "$u_long" "$LONG_WS"

p_short="$(probe_hash patched "$SHORT_WS")"
p_long="$(probe_hash patched "$LONG_WS")"
printf '  patched    %s  %s\n' "$p_short" "$SHORT_WS"
printf '  patched    %s  %s\n' "$p_long" "$LONG_WS"

if [ "$u_short" != "$u_long" ]; then
  ok "unpatched: probe output differs between the two paths"
else
  bad "unpatched: probe output was identical, so the bug did not reproduce"
fi

if [ "$p_short" = "$p_long" ]; then
  ok "patched: probe output is identical across paths"
else
  bad "patched: probe output still differs, so the fix did not take effect"
fi

note "Phase 2: which downstream actions re-execute when the path changes?"

# The build-script action's own cache key is path-independent: its env carries a
# literal ${pwd} and its inputs are exec-root-relative. So with a warm shared
# cache the second workspace would simply reuse the first workspace's bytes and
# the bug would stay invisible. Forcing the build script to run reproduces the
# real condition: a runner where it genuinely executes.
FORCE_BS="--modify_execution_info=CargoBuildScriptRun=+no-cache"

# `bazel build -s` prints a SUBCOMMAND line for every action Bazel *schedules*,
# including disk-cache hits, so grepping that text cannot tell a genuine
# re-execution from a cache hit -- both produce an identical "action '...'"
# line. Measured directly: on this repo the two are indistinguishable by that
# grep (both come out at 94), while Bazel's own summary line for the same run
# reports "82 disk cache hit, ... 12 <sandbox>" -- i.e. only 12 of those 94
# genuinely ran. --execution_log_json_file records a per-action `cacheHit`
# boolean, which is the real signal, and it does not depend on the sandbox
# strategy's name (which differs between darwin and the linux-sandbox /
# processwrapper-sandbox strategy CI uses).
executed_actions() { # mode ws_name -> "mnemonic targetLabel" of genuinely re-executed actions
  local mode="$1" ws="$2"
  local dest ob log exec_log
  dest="$(materialise "$mode" "$ws")"
  ob="$(ob_path "$mode" "$ws")-p2"
  log="$WORK/$mode-$ws-phase2.log"
  exec_log="$WORK/$mode-$ws-phase2-exec.json"
  # A prior run killed mid-build (CI timeout, SIGKILL) can leave a live server
  # and a read-only output base; go through the same hardened teardown.
  discard_output_base "$dest" "$ob"; mkdir -p "$ob"
  ( cd "$dest" && bazel --output_base="$ob" build //:myapp \
      --repository_cache="$REPO_CACHE" \
      --disk_cache="$WORK/disk_cache/$mode" \
      --execution_log_json_file="$exec_log" \
      $FORCE_BS ) >"$log" 2>&1
  # An empty or absent execution log would yield a count of zero, and zero
  # compares favourably against anything, so a silent measurement failure in one
  # mode would read as a pass. Refuse to measure what was not recorded.
  if [ ! -s "$exec_log" ] || [ "$(jq -s 'length' "$exec_log")" -eq 0 ]; then
    echo "execution log missing or empty for $mode/$ws, refusing to report a count" >&2
    discard_output_base "$dest" "$ob"
    exit 1
  fi
  jq -r 'select(.cacheHit == false) | "\(.mnemonic) \(.targetLabel)"' "$exec_log" | sort -u
  discard_output_base "$dest" "$ob"
}

for mode in unpatched patched; do
  rm -rf "$WORK/disk_cache/$mode"
  executed_actions "$mode" "$SHORT_WS" >/dev/null   # populate the cache
  second="$(executed_actions "$mode" "$LONG_WS")"
  exec_log="$WORK/$mode-$LONG_WS-phase2-exec.json"
  miss_total="$(printf '%s\n' "$second" | grep -c . || true)"
  hit_total="$(jq -s '[.[] | select(.cacheHit == true)] | length' "$exec_log")"

  # CargoBuildScriptRun is forced to re-execute by $FORCE_BS in both modes, by
  # construction -- it is expected noise, not evidence of the bug. Rustc is:
  # it is the actual compile step, so a Rustc miss here means the dependency
  # graph genuinely could not reuse a prior result.
  rust_actions="$(printf '%s\n' "$second" | grep -c '^Rustc ' || true)"
  if [ "$mode" = unpatched ]; then unpatched_count="$rust_actions"; else patched_count="$rust_actions"; fi

  printf '  %s: %s Rust compile action(s) re-executed on the second path (%s total actions re-run, %s served from disk cache)\n' \
    "$mode" "$rust_actions" "$miss_total" "$hit_total"
  printf '%s\n' "$second" | sed 's/^/      /'
done

if [ "$patched_count" -lt "$unpatched_count" ]; then
  ok "patched: fewer Rust compile actions re-execute across paths ($patched_count < $unpatched_count)"
else
  bad "patched: did not reduce Rust compile re-execution (patched=$patched_count, unpatched=$unpatched_count)"
fi

exit "$RC"
