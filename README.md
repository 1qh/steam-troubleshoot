# Steam CEF GPU Fix

Fix for Steam failing to launch on newer Linux kernels (6.13+) with NVIDIA drivers 580+/590+.

**Symptom:** Steam starts but no window ever appears. The CEF (Chromium Embedded Framework) GPU subprocess crashes 6 times, then Steam gives up:
```
FATAL:gpu_data_manager_impl_private.cc(449) GPU process isn't usable. Goodbye.
```

## Quick Start

```bash
git clone https://github.com/huylq42/steam-troubleshoot.git
cd steam-troubleshoot
make
./install.sh
./steam-fixed
```

## Tested On

| Component | Version |
|---|---|
| OS | Ubuntu 24.04 |
| Kernel | 6.17.0-14-generic |
| GPU | NVIDIA GeForce RTX 5070 Laptop (Blackwell) |
| NVIDIA driver | 590.48.01 |
| Steam CEF | Chrome/126.0.6478.183 |

Likely works on any combination of **kernel ≥ 6.13** + **NVIDIA driver ≥ 580** where Steam's GPU process crashes.

## What It Does

A single `LD_PRELOAD` library (`steam_cef_gpu_fix.so`) injected into Steam's runtime that fixes three issues:

### 1. Signal handler protection
Chrome's crashpad crash reporter installs its own `SIGSEGV`/`SIGTRAP`/`SIGILL` handlers on startup, which catch faults and kill the process. We intercept `sigaction()` and `signal()` to prevent crashpad from overriding our handlers.

### 2. NULL pointer survival
Steam ships Chrome 126's `libcef.so` which has **283 function-pointer thunks** that load an address from `.bss` (zero-initialized memory) and jump to it. On newer kernels, the constructors that should initialize these pointers fail silently, leaving them as NULL. Our `SIGSEGV` handler catches the resulting fault and returns 0 from the thunk instead of crashing.

For `NOTREACHED()` / `IMMEDIATE_CRASH()` assertions (`int3`/`ud2` instructions), we unwind **two stack frames** to skip both the crash stub and its caller — returning to the caller just one frame back causes infinite loops.

### 3. clone3() → ENOSYS
Kernel 6.13+ defaults to `clone3()` for process creation, but Chrome 126's seccomp sandbox doesn't allow it. We intercept `syscall(SYS_clone3, ...)` and return `ENOSYS`, which makes glibc fall back to the older `clone()` that the sandbox permits.

## How It Works

The install script:
1. Compiles the `.so`
2. Creates a custom Steam Runtime directory (`~/.steam/custom-steamrt/`) that symlinks to the original runtime but replaces `_v2-entry-point` with a patched version
3. The patched entry point adds `LD_PRELOAD=steam_cef_gpu_fix.so` and `--no-sandbox --disable-seccomp-filter-sandbox` flags to steamwebhelper
4. Creates `./steam-fixed` launcher and a `.desktop` entry

Steam's integrity checking only covers files inside its installation directory. Our fix lives outside it and injects via the `STEAM_RUNTIME_STEAMRT` environment variable, so Steam updates won't break it.

## Uninstall

```bash
./uninstall.sh
make clean
```

Then launch Steam normally — it will use the default runtime.

## Files

| File | Purpose |
|---|---|
| `steam_cef_gpu_fix.c` | The LD_PRELOAD library source |
| `Makefile` | Build system |
| `install.sh` | Sets up custom runtime + patches entry point |
| `uninstall.sh` | Removes custom runtime + desktop entry |

## Related Issues

- [ValveSoftware/steam-for-linux#12942](https://github.com/ValveSoftware/steam-for-linux/issues/12942) — Steam fails to start on Ubuntu 24.04 (Linux 6.14) with NVIDIA 590
- [ValveSoftware/steam-for-linux#12658](https://github.com/ValveSoftware/steam-for-linux/issues/12658) — Steam failed to launch after upgrading NVIDIA driver to 580.126.09

## License

MIT
