/*
 * steam_cef_gpu_fix.c — LD_PRELOAD fix for Steam's CEF GPU process crash
 *
 * Problem:
 *   Steam ships Chrome 126 (CEF). On newer Linux kernels (6.13+) with
 *   NVIDIA drivers 580+/590+, the GPU subprocess crashes on startup
 *   with SIGSEGV (exit_code=11) because function pointers in libcef.so's
 *   .bss section are never initialized. After 6 crashes, Chrome gives up:
 *     FATAL:gpu_data_manager_impl_private.cc(449) GPU process isn't usable.
 *   No Steam window ever appears.
 *
 * Root cause:
 *   1. Chrome 126's seccomp sandbox blocks clone3(), which kernel 6.13+
 *      prefers over clone(). This breaks process spawning inside the sandbox.
 *   2. NULL function pointers in .bss (283 thunks found) are called during
 *      GPU initialization, causing SIGSEGV.
 *   3. Chrome's crashpad handler installs its own signal handlers that
 *      override any LD_PRELOAD-based handlers, so naive signal interception
 *      doesn't work.
 *
 * Fix (this library):
 *   1. Intercepts sigaction()/signal() to prevent crashpad from overriding
 *      our signal handlers for SIGSEGV, SIGTRAP, and SIGILL.
 *   2. SIGSEGV handler: when the GPU process calls/jumps to NULL or
 *      dereferences NULL, returns 0 from the faulting function instead
 *      of crashing.
 *   3. SIGTRAP/SIGILL handler: when NOTREACHED()/IMMEDIATE_CRASH() fires
 *      (int3/ud2 instructions), unwinds two stack frames to skip both the
 *      crash stub and its caller, avoiding infinite loops.
 *   4. Intercepts clone3() syscall → returns ENOSYS, forcing glibc's
 *      fallback to clone().
 *
 * Usage:
 *   gcc -shared -fPIC -o steam_cef_gpu_fix.so steam_cef_gpu_fix.c -ldl
 *   LD_PRELOAD=./steam_cef_gpu_fix.so steam
 *   (see install.sh for the full setup via custom Steam Runtime entry point)
 *
 * Tested on:
 *   - Ubuntu 24.04, kernel 6.17.0-14-generic
 *   - NVIDIA GeForce RTX 5070 Laptop GPU (Blackwell), driver 590.48.01
 *   - Steam build 1772162887 (public beta), CEF Chrome/126.0.6478.183
 *
 * License: MIT
 */

#define _GNU_SOURCE
#include <stdarg.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ucontext.h>
#include <dlfcn.h>
#include <unistd.h>
#include <stdint.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/syscall.h>

/* ---------- state ---------- */
static int handlers_locked = 0;

/* ---------- SIGSEGV handler ---------- */
static void sigsegv_handler(int sig, siginfo_t *info, void *ucontext) {
    ucontext_t *ctx = (ucontext_t *)ucontext;
    uint64_t rip = ctx->uc_mcontext.gregs[REG_RIP];
    uint64_t rsp = ctx->uc_mcontext.gregs[REG_RSP];
    uint64_t rbp = ctx->uc_mcontext.gregs[REG_RBP];

    /* Case 1: jumped/called to NULL (rip near 0) — return 0 to caller */
    if (rip < 0x10000) {
        uint64_t ret_addr = *(uint64_t *)rsp;
        ctx->uc_mcontext.gregs[REG_RAX] = 0;
        ctx->uc_mcontext.gregs[REG_RIP] = ret_addr;
        ctx->uc_mcontext.gregs[REG_RSP] = rsp + 8;
        return;
    }

    /* Case 2: read/write to NULL — return 0 from current function */
    if ((uintptr_t)info->si_addr < 0x10000) {
        ctx->uc_mcontext.gregs[REG_RAX] = 0;
        if (rbp > 0x10000) {
            uint64_t *frame = (uint64_t *)rbp;
            ctx->uc_mcontext.gregs[REG_RBP] = frame[0];
            ctx->uc_mcontext.gregs[REG_RIP] = frame[1];
            ctx->uc_mcontext.gregs[REG_RSP] = rbp + 16;
        } else {
            ctx->uc_mcontext.gregs[REG_RIP] = *(uint64_t *)rsp;
            ctx->uc_mcontext.gregs[REG_RSP] = rsp + 8;
        }
        return;
    }

    /* Non-NULL fault — genuine crash, restore default and re-raise */
    struct sigaction sa = { .sa_handler = SIG_DFL };
    sigaction(SIGSEGV, &sa, NULL);
    handlers_locked = 0;
    raise(SIGSEGV);
}

/* ---------- SIGTRAP / SIGILL handler (NOTREACHED / IMMEDIATE_CRASH) ---------- */
static void crash_handler(int sig, siginfo_t *info, void *ucontext) {
    ucontext_t *ctx = (ucontext_t *)ucontext;
    uint64_t rip = ctx->uc_mcontext.gregs[REG_RIP];
    uint64_t rbp = ctx->uc_mcontext.gregs[REG_RBP];
    uint8_t *insn = (uint8_t *)rip;

    int is_crash = (insn[0] == 0xcc)                       /* int3  */
                || (insn[0] == 0x0f && insn[1] == 0x0b);   /* ud2   */

    if (is_crash && rbp > 0x10000) {
        /*
         * NOTREACHED stub layout:  push rbp; mov rbp,rsp; int3; ud2; int3
         * When we land here the stub has set up its own frame.
         * Returning to the direct caller (the function that called NOTREACHED)
         * often causes infinite loops because that caller retries.
         * Instead, skip TWO frames — return to the caller's caller.
         */
        uint64_t *stub_frame   = (uint64_t *)rbp;
        uint64_t caller_rbp    = stub_frame[0];

        if (caller_rbp > 0x10000) {
            uint64_t *caller_frame = (uint64_t *)caller_rbp;
            ctx->uc_mcontext.gregs[REG_RAX] = 0;
            ctx->uc_mcontext.gregs[REG_RBP] = caller_frame[0];
            ctx->uc_mcontext.gregs[REG_RIP] = caller_frame[1];
            ctx->uc_mcontext.gregs[REG_RSP] = caller_rbp + 16;
            return;
        }

        /* Single-frame fallback */
        ctx->uc_mcontext.gregs[REG_RAX] = 0;
        ctx->uc_mcontext.gregs[REG_RBP] = caller_rbp;
        ctx->uc_mcontext.gregs[REG_RIP] = stub_frame[1];
        ctx->uc_mcontext.gregs[REG_RSP] = rbp + 16;
        return;
    }

    /* Not a crash stub — restore default */
    struct sigaction sa = { .sa_handler = SIG_DFL };
    sigaction(sig, &sa, NULL);
    handlers_locked = 0;
    raise(sig);
}

/* ---------- sigaction() interception ---------- */
/*
 * Chrome's crashpad installs its own SIGSEGV/SIGTRAP/SIGILL handlers
 * on startup, overriding ours. We intercept sigaction() and silently
 * refuse to replace our handlers for those three signals.
 */
typedef int (*real_sigaction_t)(int, const struct sigaction *, struct sigaction *);
static real_sigaction_t real_sigaction_fn = NULL;

int sigaction(int signum, const struct sigaction *act, struct sigaction *oldact) {
    if (!real_sigaction_fn)
        real_sigaction_fn = (real_sigaction_t)dlsym(RTLD_NEXT, "sigaction");

    if (handlers_locked && act != NULL &&
        (signum == SIGSEGV || signum == SIGTRAP || signum == SIGILL)) {
        if (oldact)
            real_sigaction_fn(signum, NULL, oldact);
        return 0;   /* pretend we set it */
    }
    return real_sigaction_fn(signum, act, oldact);
}

typedef void (*sighandler_t)(int);
sighandler_t signal(int signum, sighandler_t handler) {
    if (handlers_locked &&
        (signum == SIGSEGV || signum == SIGTRAP || signum == SIGILL))
        return SIG_DFL;

    struct sigaction sa_old, sa_new;
    memset(&sa_new, 0, sizeof(sa_new));
    sa_new.sa_handler = handler;
    sigemptyset(&sa_new.sa_mask);
    if (!real_sigaction_fn)
        real_sigaction_fn = (real_sigaction_t)dlsym(RTLD_NEXT, "sigaction");
    real_sigaction_fn(signum, &sa_new, &sa_old);
    return sa_old.sa_handler;
}

/* ---------- clone3() interception ---------- */
/*
 * Kernel 6.13+ prefers clone3() but Chrome 126's seccomp sandbox
 * blocks it. Returning ENOSYS forces glibc to fall back to clone().
 */
typedef long (*syscall_fn_t)(long, ...);
static syscall_fn_t real_syscall = NULL;

long syscall(long number, ...) {
    if (!real_syscall)
        real_syscall = (syscall_fn_t)dlsym(RTLD_NEXT, "syscall");

    if (number == SYS_clone3) {
        errno = ENOSYS;
        return -1;
    }

    va_list ap;
    va_start(ap, number);
    long a1 = va_arg(ap, long);
    long a2 = va_arg(ap, long);
    long a3 = va_arg(ap, long);
    long a4 = va_arg(ap, long);
    long a5 = va_arg(ap, long);
    long a6 = va_arg(ap, long);
    va_end(ap);
    return real_syscall(number, a1, a2, a3, a4, a5, a6);
}

/* ---------- constructor ---------- */
__attribute__((constructor(101)))
static void init(void) {
    if (!real_sigaction_fn)
        real_sigaction_fn = (real_sigaction_t)dlsym(RTLD_NEXT, "sigaction");

    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&sa.sa_mask);

    sa.sa_sigaction = sigsegv_handler;
    real_sigaction_fn(SIGSEGV, &sa, NULL);

    sa.sa_sigaction = crash_handler;
    real_sigaction_fn(SIGTRAP, &sa, NULL);
    real_sigaction_fn(SIGILL,  &sa, NULL);

    handlers_locked = 1;
}
