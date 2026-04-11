/*
 * ntiny minimal init: prints a banner and loops forever.
 *
 * No libc dependencies — uses raw RV32 Linux syscalls directly.
 * The kernel opens /dev/console as fd 0/1/2 before exec'ing init,
 * provided the cpio archive contains a /dev/console device node
 * (char major 5 minor 1). The accompanying cpio_list does that.
 *
 * Build with the riscv32-unknown-linux-gnu toolchain (static, nostdlib):
 *   riscv32-unknown-linux-gnu-gcc -static -nostdlib -nostartfiles \
 *       -march=rv32imac -mabi=ilp32 -Os -o init init.c
 */

typedef unsigned int  size_t;
typedef int           ssize_t;

/* RV32 Linux syscall numbers (from <asm/unistd.h>) */
#define SYS_write       64
#define SYS_exit_group  94
#define SYS_nanosleep   101

/* Generic ecall wrapper for 3-arg syscalls. */
static inline long syscall3(long n, long a0, long a1, long a2)
{
    register long _a0 asm("a0") = a0;
    register long _a1 asm("a1") = a1;
    register long _a2 asm("a2") = a2;
    register long _a7 asm("a7") = n;
    asm volatile ("ecall"
                  : "+r"(_a0)
                  : "r"(_a1), "r"(_a2), "r"(_a7)
                  : "memory");
    return _a0;
}

static size_t mystrlen(const char *s)
{
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

static void print(const char *s)
{
    syscall3(SYS_write, 1, (long)s, (long)mystrlen(s));
}

/* Ditch ELF startup, the kernel jumps straight to _start. */
void _start(void)
{
    print("\n");
    print("================================================\n");
    print("  ntiny RISC-V SoC: Linux booted to userspace!  \n");
    print("================================================\n");
    print("\n");
    print("Init PID 1 reached. Looping forever (no shell).\n");
    print("Press Ctrl-C in the simulator to stop.\n");

    /* Loop forever without exiting. Use nanosleep so we don't peg the CPU. */
    struct {
        long sec;
        long nsec;
    } ts = { 60, 0 };

    for (;;) {
        syscall3(SYS_nanosleep, (long)&ts, 0, 0);
    }
}
