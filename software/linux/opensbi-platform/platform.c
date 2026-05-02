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

/* ── ntiny UART registers ────────────────────────────────────── */
#define UART_TX         0x04
#define UART_STATUS     0x08
#define UART_STATUS_TXFULL  (1 << 3)
#define UART_BAUDRATE   0x10
#define UART_CONTROL    0x0C

/* ── UART console driver ─────────────────────────────────────── */
static volatile void *uart_base;

static void ntiny_uart_putc(char c)
{
    /* At 250000 baud one byte takes ~2000 cycles to shift out — small
       enough that polling TXFULL is affordable, and necessary so the
       SoC paces TX bytewise. Without pacing, back-to-back writes can
       race the uartdpi RX state machine and corrupt PTS output. */
    while (readl(uart_base + UART_STATUS) & UART_STATUS_TXFULL)
        ;
    writel(c, uart_base + UART_TX);
}

static int ntiny_uart_getc(void)
{
    /* RX not implemented for now — return -1 (no char) */
    return -1;
}

static struct sbi_console_device ntiny_uart = {
    .name = "ntiny-uart",
    .console_putc = ntiny_uart_putc,
    .console_getc = ntiny_uart_getc,
};

static void ntiny_uart_init(void)
{
    uart_base = (void *)NTINY_UART_ADDR;

    /* Reset TX/RX + enable interrupts (same as bare-metal uart_init) */
    writel((1 << 2) | (1 << 1) | (1 << 0), uart_base + UART_CONTROL);
    /* Baud rate = clk / (baud + 1). 250000 baud: 50MHz/250000 - 1 = 199.
       Compromise between 115200 (slow sim wallclock from polling-free
       per-symbol TX delay) and 1M+ (uartdpi RX state machine races
       SoC TX at high rates). testbench/tb_soc_top.v BAUD must match. */
    writel(199, uart_base + UART_BAUDRATE);

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
        [0] = { 0, -1 },   /* hart 0: M-mode context only, no S-mode context */
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
     */
    csr_set(CSR_MENVCFGH, BIT(29));
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
