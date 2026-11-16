//
// AIOCrashNotes.h
// For AIOStreamsHost's crash notes: what a fatal signal leaves in the AIOStreams log, written
// from inside the signal handler with nothing but write(): the fault address, the thread, whether
// the fault is at the end of the thread's stack (a stack overflow), and the crashed thread's own
// stack from the signal's context. And an alternate signal stack, so the handler still runs when
// the thread's stack is used up.
//

#ifndef AIOCrashNotes_h
#define AIOCrashNotes_h

#include <dlfcn.h>
#include <execinfo.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <unistd.h>

static inline void nuvio_crash_write(int fd, const char *text) {
    (void)write(fd, text, strlen(text));
}

static inline void nuvio_crash_write_hex(int fd, uintptr_t value) {
    char buffer[18];
    buffer[0] = '0';
    buffer[1] = 'x';
    for (int i = 0; i < 16; i++) {
        unsigned nibble = (unsigned)((value >> ((15 - i) * 4)) & 0xF);
        buffer[2 + i] = (char)(nibble < 10 ? '0' + nibble : 'a' + nibble - 10);
    }
    (void)write(fd, buffer, sizeof buffer);
}

typedef int (*nuvio_sigaltstack_function)(const stack_t *, stack_t *);

/// An alternate stack for signal handlers on the calling thread (kept for as long as the thread
/// lives); nothing when it has one already. The tvOS SDK marks sigaltstack unavailable, while the
/// system has it: looked up at run time, and left out when it isn't there. 1: the thread has one.
static inline int NuvioInstallAlternateSignalStack(void) {
    nuvio_sigaltstack_function sigaltstack_call = (nuvio_sigaltstack_function)dlsym(RTLD_DEFAULT, "sigaltstack");
    if (sigaltstack_call == NULL) return 0;
    stack_t current;
    if (sigaltstack_call(NULL, &current) == 0 && !(current.ss_flags & SS_DISABLE) && current.ss_sp != NULL) {
        return 1;
    }
    size_t size = 256 * 1024;
    void *memory = malloc(size);
    if (memory == NULL) return 0;
    stack_t alternate;
    alternate.ss_sp = memory;
    alternate.ss_size = size;
    alternate.ss_flags = 0;
    if (sigaltstack_call(&alternate, NULL) != 0) {
        free(memory);
        return 0;
    }
    return 1;
}

/// From the signal handler: a line with the fault address and the thread, then the crashed
/// thread's stack (from the context's pc, lr and frame pointers, within the thread's stack).
static inline void NuvioNoteCrash(int fd, siginfo_t *info, void *context) {
    if (fd < 0) return;
    pthread_t thread = pthread_self();
    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(thread);
    uintptr_t bottom = top - (uintptr_t)pthread_get_stacksize_np(thread);
    char name[64];
    memset(name, 0, sizeof name);
    pthread_getname_np(thread, name, sizeof name);

    nuvio_crash_write(fd, "[nuvio] crash: fault address ");
    nuvio_crash_write_hex(fd, info != NULL ? (uintptr_t)info->si_addr : 0);
    nuvio_crash_write(fd, " · thread \"");
    nuvio_crash_write(fd, name[0] != 0 ? name : (pthread_main_np() ? "main" : "?"));
    nuvio_crash_write(fd, "\"");
    if (info != NULL) {
        uintptr_t address = (uintptr_t)info->si_addr;
        if (address + 256 * 1024 >= bottom && address < bottom + 256 * 1024) {
            nuvio_crash_write(fd, " · STACK OVERFLOW: the fault is at the end of the thread's stack");
        }
    }
    nuvio_crash_write(fd, "\n[nuvio] crashed stack:\n");

    void *frames[64];
    int count = 0;
#if defined(__arm64__)
    if (context != NULL) {
        ucontext_t *uc = (ucontext_t *)context;
#if defined(__darwin_arm_thread_state64_get_pc)
        uintptr_t pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
        uintptr_t lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
        uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
#else
        uintptr_t pc = (uintptr_t)uc->uc_mcontext->__ss.__pc;
        uintptr_t lr = (uintptr_t)uc->uc_mcontext->__ss.__lr;
        uintptr_t fp = (uintptr_t)uc->uc_mcontext->__ss.__fp;
#endif
        frames[count++] = (void *)pc;
        frames[count++] = (void *)lr;
        while (count < 64 && fp >= bottom && fp + 16 <= top && (fp & 0xF) == 0) {
            uintptr_t next = ((uintptr_t *)fp)[0];
            uintptr_t ret = ((uintptr_t *)fp)[1];
            if (ret == 0) break;
            frames[count++] = (void *)ret;
            if (next <= fp) break;
            fp = next;
        }
    }
#endif
    if (count > 0) {
        backtrace_symbols_fd(frames, count, fd);
    } else {
        count = backtrace(frames, 64);
        backtrace_symbols_fd(frames, count, fd);
    }
}

#endif /* AIOCrashNotes_h */
