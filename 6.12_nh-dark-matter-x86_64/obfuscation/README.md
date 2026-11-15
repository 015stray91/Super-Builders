# Obfuscation toolchain notes

Two obfuscators are used at compile time:

| Tool | Source | Role |
|---|---|---|
| goat (Hellscape) | `015stray91/gimple-GCC-obfuscation-` | GCC plugin, GIMPLE passes |
| Tigress | `015stray91/Hikari-LLVM19` + Tigress 4.1.0 | Source-level C obfuscator |

## goat

Build the plugin **with the same GCC the kernel is built with**, otherwise
`plugin_default_version_check()` rejects it.

```sh
git clone https://github.com/015stray91/gimple-GCC-obfuscation-.git goat-src
cd goat-src && patch -p1 < gcc14-api-fixes.patch
mkdir build && cd build && CC=gcc cmake .. -DCMAKE_BUILD_TYPE=Release && make -j
```

Produces `hellscape.so`.

### Pass status against Linux 6.12 kernel code

| Pass | Flag | Kernel sources |
|---|---|---|
| Substitution | `-fplugin-arg-hellscape-sub` | **works** (only safe pass) |
| Flattening | `-fplugin-arg-hellscape-fla` | crashes |
| Bogus control flow | `-fplugin-arg-hellscape-bcf` | crashes |

Only `-sub` is safe. FLA and BCF build a switch/loop dispatch over every basic
block and segfault inside GCC on the kernel's computed-goto and
non-reducible flow graphs.

The seed must be exactly 8 hex digits, e.g. `-fplugin-arg-hellscape-seed=deadbeef`.

## Tigress

Needs `--Transform=Virtualize` on the C source, then GCC compiles the generated
VM. That requires a **complete** Tigress 4.1.0 tree: `tigress`, `cilly`, the
`App::Cilly` Perl modules and the CIL engine.

The copy in `kali-nethunter-kernel-builder-main/tigress/4.1.0` is incomplete —
2.9 MB of wrapper scripts only. `cilly` aborts with
`Can't locate App/Cilly/CilConfig.pm`, so Virtualize cannot run from it.
Supply the full Tigress 4.1.0 Linux-x86_64 distribution to enable it.
