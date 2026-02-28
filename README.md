# Steam CEF GPU Fix

Fix for Steam failing to launch on newer Linux kernels (6.13+) with NVIDIA drivers 580+/590+.

**Symptom:** Steam starts but no window ever appears. The CEF (Chromium Embedded Framework) GPU subprocess crashes 6 times, then Steam gives up:
```
FATAL:gpu_data_manager_impl_private.cc(449) GPU process isn't usable. Goodbye.
```

## Root Cause

Steam's steamwebhelper (Chrome 126) calls `vaInitialize()` from **libva** during early startup (in the zygote process). On systems without a VA-API driver backend, libva calls through a NULL function pointer at offset `0x78` in its driver vtable — the pointer that should have been populated by a backend driver (`*_drv_video.so`) was never set.

Normally this would just return an error, but Chrome's **crashpad** crash reporter installs its own `SIGSEGV` handler that catches the fault and kills the entire process. After 6 GPU process crashes, Chrome gives up and Steam exits.

## Fix 1: Install the VA-API driver (recommended)

The simplest fix — install the NVIDIA VA-API driver so `vaInitialize()` doesn't crash:

```bash
sudo apt install nvidia-vaapi-driver
steam
```

No code, no LD_PRELOAD, no wrappers. Steam launches normally.

**Tested on:** Ubuntu 24.04 with kernel 6.17 and NVIDIA 590.48.01.

## Fix 2: LD_PRELOAD library (fallback)

If you can't install the VA-API driver (no root, distro doesn't package it, etc.):

```bash
git clone https://github.com/huylq42/steam-troubleshoot.git
cd steam-troubleshoot
make
LD_PRELOAD=$PWD/steam_cef_gpu_fix.so steam
```

To make it permanent, add an alias to your `~/.bashrc`:
```bash
echo 'alias steam="LD_PRELOAD=$HOME/steam-troubleshoot/steam_cef_gpu_fix.so steam"' >> ~/.bashrc
```

### What the library does

1. **SIGSEGV handler** — catches the NULL function pointer call in `vaInitialize()` and returns 0 instead of crashing. Also handles NULL-pointer dereferences gracefully.

2. **sigaction() interception** — prevents Chrome's crashpad from overriding our signal handler. Without this, crashpad replaces our handler on startup and the fix doesn't work.

3. **SIGTRAP/SIGILL handler** (safety net) — handles `NOTREACHED()` / `IMMEDIATE_CRASH()` assertions (`int3`/`ud2` instructions) by unwinding two stack frames.

4. **clone3() → ENOSYS** (safety net) — forces glibc to fall back to `clone()` when kernel 6.13+ defaults to `clone3()`, which Chrome 126's seccomp sandbox blocks.

### How LD_PRELOAD reaches steamwebhelper

Steam's `_v2-entry-point` script captures `LD_PRELOAD` from the environment and forwards it into the pressure-vessel container via `--ld-preloads`. So `LD_PRELOAD=our.so steam` is all that's needed — the library loads into steamwebhelper and all its child processes automatically.

Steam's integrity checking only covers files inside its installation directory. The fix lives outside it, so Steam updates won't break it.

## Tested On

| Component | Version |
|---|---|
| OS | Ubuntu 24.04 |
| Kernel | 6.17.0-14-generic |
| GPU | NVIDIA GeForce RTX 5070 Laptop (Blackwell) |
| NVIDIA driver | 590.48.01 |
| Steam CEF | Chrome/126.0.6478.183 |

Likely works on any combination of **kernel ≥ 6.13** + **NVIDIA driver ≥ 580** where Steam's GPU process crashes.

## Uninstall

**Fix 1:** `sudo apt remove nvidia-vaapi-driver` (though there's no reason to remove it).

**Fix 2:** Stop using `LD_PRELOAD` — no files inside Steam's directory are modified. Remove the alias from `~/.bashrc` if you added one.

## Related Issues

- [ValveSoftware/steam-for-linux#12942](https://github.com/ValveSoftware/steam-for-linux/issues/12942) — Steam fails to start on Ubuntu 24.04 (Linux 6.14) with NVIDIA 590
- [ValveSoftware/steam-for-linux#12658](https://github.com/ValveSoftware/steam-for-linux/issues/12658) — Steam failed to launch after upgrading NVIDIA driver to 580.126.09

## License

MIT
