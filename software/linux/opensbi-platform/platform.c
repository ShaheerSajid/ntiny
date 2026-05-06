/*
 * SPDX-License-Identifier: BSD-2-Clause
 *
 * ntiny RISC-V SoC platform support for OpenSBI.
 *
 * Hardware: RV32IMACSU, Sv32 MMU, CLINT, PLIC, custom UART.
 * Single hart, 16MB RAM at 0x80000000.
 */

#include <sbi/riscv_asm.h>
#include <sbi/riscv_io.h>
#include <sbi/riscv_encoding.h>
#include <sbi/sbi_bitops.h>
#include <sbi/sbi_const.h>
#include <sbi/sbi_console.h>
#include <sbi/sbi_platform.h>
#include <sbi_utils/ipi/aclint_mswi.h>
#include <sbi_utils/irqchip/plic.h>
#include <sbi_utils/timer/aclint_mtimer.h>

/* ── Hardware addresses ──────────────────────────────────────── */
#define NTINY_CLINT_ADDR        0x02000000UL
#define NTINY_PLIC_ADDR         0x0C000000UL
#define NTINY_PLIC_SIZE         0x02000000UL
#define NTINY_PLIC_NUM_SRC      6
#define NTINY_UART_ADDR         0x10000000UL
#define NTINY_TIMER_FREQ        50000000UL  /* 50 MHz */

/* ── ntiny UART registers (sifive,uart0 layout, Phase 2b) ────── */
#define UART_TXDATA     0x00    /* W: data; R: bit 31 = full flag      */
#define UART_RXDATA     0x04    /* R: bit 31 = empty, bits[7:0] = data */
#define UART_TXCTRL     0x08    /* bit 0 = txen, bit 1 = nstop         */
#define UART_RXCTRL     0x0C    /* bit 0 = rxen                        */
#define UART_IE         0x10
#define UART_IP         0x14
#define UART_DIV        0x18

#define UART_TXDATA_FULL_BIT   (1u << 31)
#define UART_RXDATA_EMPTY_BIT  (1u << 31)
#define UART_TXCTRL_TXEN       (1u << 0)
#define UART_RXCTRL_RXEN       (1u << 0)

/* ── UART console driver ─────────────────────────────────────── */
static volatile void *uart_base;

static void ntiny_uart_putc(char c)
{
    /* Poll txdata.full (bit 31) so we don't over-write the in-flight
       byte. At 250 kbaud this is ~2000 cycles per byte — affordable. */
    while (readl(uart_base + UART_TXDATA) & UART_TXDATA_FULL_BIT)
        ;
    writel((unsigned int)(unsigned char)c, uart_base + UART_TXDATA);
}

static int ntiny_uart_getc(void)
{
    /* SiFive convention: rxdata read returns bit 31 = "empty" if no
       byte available, else bits [7:0] = the byte (and dequeues it). */
    unsigned int v = readl(uart_base + UART_RXDATA);
    if (v & UART_RXDATA_EMPTY_BIT)
        return -1;
    return v & 0xff;
}

static struct sbi_console_device ntiny_uart = {
    .name = "ntiny-uart",
    .console_putc = ntiny_uart_putc,
    .console_getc = ntiny_uart_getc,
};

static void ntiny_uart_init(void)
{
    uart_base = (void *)NTINY_UART_ADDR;

    /* SiFive convention (matches drivers/tty/serial/sifive.c): div = clk
       / baud - 1. For 250 kbaud at 50 MHz that's 199. testbench BAUD
       must match the parameter compiled into uartdpi. */
    writel(199, uart_base + UART_DIV);
    writel(UART_TXCTRL_TXEN, uart_base + UART_TXCTRL);
    writel(UART_RXCTRL_RXEN, uart_base + UART_RXCTRL);

    sbi_console_set_device(&ntiny_uart);
}

/* ── ACLINT (CLINT) timer + IPI ──────────────────────────────── */
static struct aclint_mswi_data mswi = {
    .addr       = NTINY_CLINT_ADDR + CLINT_MSWI_OFFSET,
    .size       = ACLINT_MSWI_SIZE,
    .first_hartid = 0,
    .hart_count = 1,
};

static struct aclint_mtimer_data mtimer = {
    .mtime_freq    = NTINY_TIMER_FREQ,
    .mtime_addr    = NTINY_CLINT_ADDR + CLINT_MTIMER_OFFSET +
                     ACLINT_DEFAULT_MTIME_OFFSET,
    .mtime_size    = ACLINT_DEFAULT_MTIME_SIZE,
    .mtimecmp_addr = NTINY_CLINT_ADDR + CLINT_MTIMER_OFFSET +
                     ACLINT_DEFAULT_MTIMECMP_OFFSET,
    .mtimecmp_size = ACLINT_DEFAULT_MTIMECMP_SIZE,
    .first_hartid  = 0,
    .hart_count    = 1,
    .has_64bit_mmio = true,
};

/* ── PLIC ─────────────────────────────────────────────────────── */
static struct plic_data plic = {
    .unique_id   = 0,
    .addr        = NTINY_PLIC_ADDR,
    .size        = NTINY_PLIC_SIZE,
    .num_src     = NTINY_PLIC_NUM_SRC,
    .context_map = {
        [0] = { 0, 1 },    /* hart 0: M-mode = ctx 0, S-mode = ctx 1 */
    },
};

/* ── Platform operations ──────────────────────────────────────── */
static int ntiny_early_init(bool cold_boot)
{
    if (!cold_boot)
        return 0;

    ntiny_uart_init();
    return aclint_mswi_cold_init(&mswi);
}

static int ntiny_final_init(bool cold_boot)
{
    /* Enable Svadu (HW A/D PTE updates). menvcfg.ADUE = bit 61 ->
     * menvcfgh[29] on rv32. Linux's trap entry stores to thread_info
     * pages with D=0; without ADUE=1 the PTW page-faults and the
     * trap handler itself page-faults saving context -> boot hang.
     *
     * Enable Sstc (S-mode timer compare). menvcfg.STCE = bit 63 ->
     * menvcfgh[31] on rv32. With STCE=1 the kernel can program
     * stimecmp directly via CSR write, eliminating one SBI ecall per
     * scheduler tick. Linux discovers Sstc via DT riscv,isa-extensions
     * and the supervisor-side bit in mhartid extensions.
     */
    csr_set(CSR_MENVCFGH, BIT(29) | BIT(31));
    return 0;
}

static int ntiny_irqchip_init(void)
{
    return plic_cold_irqchip_init(&plic);
}

static int ntiny_timer_init(void)
{
    return aclint_mtimer_cold_init(&mtimer, NULL);
}

/* ── Platform descriptor ──────────────────────────────────────── */
const struct sbi_platform_operations platform_ops = {
    .early_init   = ntiny_early_init,
    .final_init   = ntiny_final_init,
    .irqchip_init = ntiny_irqchip_init,
    .timer_init   = ntiny_timer_init,
};

const struct sbi_platform platform = {
    .opensbi_version   = OPENSBI_VERSION,
    .platform_version  = SBI_PLATFORM_VERSION(0x0, 0x01),
    .name              = "ntiny",
    .features          = SBI_PLATFORM_DEFAULT_FEATURES,
    .hart_count        = 1,
    .hart_stack_size   = SBI_PLATFORM_DEFAULT_HART_STACK_SIZE,
    .heap_size         = SBI_PLATFORM_DEFAULT_HEAP_SIZE(1),
    .platform_ops_addr = (unsigned long)&platform_ops,
};
