# rules_rust build-script cache bust

`rules_rust` build scripts bake the absolute build path into their output, which poisons the Bazel cache key of every crate downstream. One line fixes it.

## What happens

`rustix`'s `build.rs` probes for compiler features by running `rustc` with the source piped in on stdin:

```rust
cmd.arg("--crate-type=rlib").arg("--emit=metadata").arg("-o").arg(out_file);
cmd.arg("-")   // source on stdin
```

Because the source arrives on stdin, no source path reaches `rustc`. Its working directory is the only path input it has, and `rustc` folds that into the metadata it emits. The probe writes that output to `$OUT_DIR/rustix_test_can_compile`, a declared build-script output, and `rules_rust` hashes build-script outputs into the cache key of every dependent crate.

Under Bazel the build script's working directory is the exec root:

```
<output_base>/execroot/_main
```

Same source, two different absolute paths, different bytes in that file, and different cache keys for everything downstream of it.

## Why it only bites sometimes

Bazel's default output base is an MD5 of the workspace path. A CI job that always checks out to `/home/runner/work/repo/repo` gets the same exec root every run, so its output is stable and nothing looks wrong.

The divergence appears when a cache is shared across environments whose checkout paths differ: a developer's machine and CI, two differently-configured runners, a container and a host.

Even then it stays hidden while the cache is warm: the `CargoBuildScriptRun` action's own cache key is path-independent (its env carries a literal `${pwd}` placeholder, its inputs are exec-root-relative), so a cached result is reused whatever the path. It bites when the build script actually executes at a new path: cold cache, eviction, a new runner, first population. That run writes different bytes, and every crate downstream misses.

Hence intermittent, environment-dependent cache misses on unchanged source.

## The fix

One line in `cargo/private/cargo_build_script.bzl`:

```python
env["CARGO_ENCODED_RUSTFLAGS"] = "\\x1f".join([
    "--sysroot=${{pwd}}/{}".format(toolchain.sysroot),
    "--remap-path-prefix=${pwd}=.",
] + ctx.attr.rustc_flags)
```

`build.rs` forwards `CARGO_ENCODED_RUSTFLAGS` verbatim into its probe, so the flag reaches `rustc`. (No `.format()` on the new line, because `${pwd}` needs single braces, and is substituted at runtime by the build-script runner.)

This is already the rule everywhere else. `construct_arguments()` (`rust/private/rustc.bzl:928`) applies `--remap-path-prefix` to every rustc invocation `rules_rust` builds, *"For determinism to help with build distribution and such"*:

| Invocation | Remapped |
| --- | --- |
| `rust_library` / `rust_binary`, metadata, clippy, unpretty | yes |
| rustdoc | no, documented, needs `-Zunstable-options` |
| build script | no, with no stated reason |

Build scripts reach `rustc` indirectly, through the environment rather than `construct_arguments()`, so they never inherited it.

## Reproduce

```
nix develop -c ./minimal-repro.sh   # seconds, no Bazel
nix develop -c ./prove.sh           # ~12 min, four Bazel workspaces
```

`minimal-repro.sh` isolates the mechanism to `rustc` and two directories. The unpatched hashes differ, and differ again on every run; the patched hash is identical every time.

`prove.sh` builds `mylib` → `rustix` and `myapp` → `mylib` in four workspaces (unpatched/patched × short/long path, each with an explicit `--output_base`), then measures downstream re-execution against a shared disk cache.

## Result

```
Phase 1: probe output
  unpatched  e27190bc…  (short path)
  unpatched  01079d73…  (long path)     differ
  patched    7e887e12…  (both paths)    identical

Phase 2: downstream re-execution on the second path
  unpatched  3 Rustc actions re-executed:  rustix, //:mylib, //:myapp
  patched    0
```

The whole chain re-executes, not just `rustix`.

Phase 2 passes `--modify_execution_info=CargoBuildScriptRun=+no-cache` to force the build script to genuinely run on both paths, reproducing the cold-cache condition above. That also makes nine `CargoBuildScriptRun` actions re-run in both modes. Noise, not evidence. Read the `Rustc` lines.

## CI proves it on Linux

The numbers above are from `aarch64-darwin`. The CI pipeline in `.github/workflows/prove.yml` runs both scripts on `ubuntu-latest` on every push, and proves the same issue there:

```
Phase 1: probe output
  unpatched  4ae13a03…  3f70801a…   differ
  patched    4d90df4d…  4d90df4d…   identical

Phase 2: 3 Rustc actions re-executed, patched 0
```

Different absolute hashes, same behaviour. The values are platform-specific; the divergence and the counts are not. So this is not an artifact of one machine or one toolchain.

## Notes

- `patches/` holds the fix, applied via `single_version_override` against BCR `rules_rust` 0.73.0. `rustix` is pinned `=1.1.4` with lockfiles committed, so two workspaces in a pair can differ only by path.
- Covers what a build script forwards to `rustc`. A build script that embeds its working directory some other way is out of scope.
