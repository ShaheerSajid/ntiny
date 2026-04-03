/* CLINT timer test — verifies mtime, mtimecmp, and timer interrupt */
#include "init.h"
#include "uart.h"
#include "ee_printf.h"
#include "tohost.h"
#include "csr.h"
#include "mem_map.h"

#define CLINT_BASE      0x02000000UL
#define CLINT_MSIP      (*(volatile uint32_t *)(CLINT_BASE + 0x0000))
#define CLINT_MTIMECMP_LO (*(volatile uint32_t *)(CLINT_BASE + 0x4000))
#define CLINT_MTIMECMP_HI (*(volatile uint32_t *)(CLINT_BASE + 0x4004))
#define CLINT_MTIME_LO  (*(volatile uint32_t *)(CLINT_BASE + 0xBFF8))
#define CLINT_MTIME_HI  (*(volatile uint32_t *)(CLINT_BASE + 0xBFFC))

static volatile int timer_fired = 0;
static volatile int soft_fired = 0;

/* Override the timer ISR */
void ISR_TIMER_ASM(void) __attribute__((interrupt("machine")));
void ISR_TIMER_ASM(void) {
    timer_fired++;
    /* Clear timer by setting mtimecmp far in the future */
    CLINT_MTIMECMP_HI = 0xFFFFFFFF;
    CLINT_MTIMECMP_LO = 0xFFFFFFFF;
}

void ISR_SOFT_ASM(void) __attribute__((interrupt("machine")));
void ISR_SOFT_ASM(void) {
    soft_fired++;
    CLINT_MSIP = 0;  /* Clear software interrupt */
}

int main(void) {
    int errors = 0;
    uart_init(115200);

    ee_printf("\n=== CLINT Timer Test ===\n\n");

    /* Test 1: mtime is advancing */
    uint32_t t1 = CLINT_MTIME_LO;
    for (volatile int i = 0; i < 100; i++);  /* small delay */
    uint32_t t2 = CLINT_MTIME_LO;
    ee_printf("Test 1 - mtime advances: t1=%u t2=%u ", t1, t2);
    if (t2 > t1) {
        ee_printf("PASS (delta=%u)\n", t2 - t1);
    } else {
        ee_printf("FAIL\n");
        errors++;
    }

    /* Test 2: TIME CSR matches mtime */
    uint32_t csr_time = csr_read(0xC01);  /* TIME */
    uint32_t mmio_time = CLINT_MTIME_LO;
    int32_t diff = (int32_t)(mmio_time - csr_time);
    ee_printf("Test 2 - TIME CSR: csr=%u mmio=%u ", csr_time, mmio_time);
    if (diff >= 0 && diff < 100) {  /* should be very close */
        ee_printf("PASS (diff=%d)\n", diff);
    } else {
        ee_printf("FAIL (diff=%d)\n", diff);
        errors++;
    }

    /* Test 3: TIMEH CSR */
    uint32_t csr_timeh = csr_read(0xC81);  /* TIMEH */
    uint32_t mmio_timeh = CLINT_MTIME_HI;
    ee_printf("Test 3 - TIMEH CSR: csr=%u mmio=%u ", csr_timeh, mmio_timeh);
    if (csr_timeh == mmio_timeh) {
        ee_printf("PASS\n");
    } else {
        ee_printf("FAIL\n");
        errors++;
    }

    /* Test 4: mtimecmp write/read */
    CLINT_MTIMECMP_LO = 0x12345678;
    CLINT_MTIMECMP_HI = 0x9ABCDEF0;
    uint32_t cmp_lo = CLINT_MTIMECMP_LO;
    uint32_t cmp_hi = CLINT_MTIMECMP_HI;
    ee_printf("Test 4 - mtimecmp RW: lo=%08x hi=%08x ", cmp_lo, cmp_hi);
    if (cmp_lo == 0x12345678 && cmp_hi == 0x9ABCDEF0) {
        ee_printf("PASS\n");
    } else {
        ee_printf("FAIL\n");
        errors++;
    }

    /* Test 5: Timer interrupt */
    /* Reset mtimecmp to max to avoid premature interrupt */
    CLINT_MTIMECMP_HI = 0xFFFFFFFF;
    CLINT_MTIMECMP_LO = 0xFFFFFFFF;
    timer_fired = 0;

    /* Enable M-mode timer interrupt */
    csr_set(mie, (1 << 7));   /* MTIE */
    csr_set(mstatus, (1 << 3)); /* MIE */

    /* Set mtimecmp = mtime + 1000 (fire in ~1000 cycles) */
    uint32_t target = CLINT_MTIME_LO + 1000;
    CLINT_MTIMECMP_HI = 0;
    CLINT_MTIMECMP_LO = target;

    /* Wait for interrupt */
    for (volatile int i = 0; i < 10000 && !timer_fired; i++);

    ee_printf("Test 5 - Timer IRQ: fired=%d ", timer_fired);
    if (timer_fired > 0) {
        ee_printf("PASS\n");
    } else {
        ee_printf("FAIL\n");
        errors++;
    }

    /* Disable interrupts */
    csr_clear(mstatus, (1 << 3));

    /* Test 6: Software interrupt (msip) */
    soft_fired = 0;
    csr_set(mie, (1 << 3));   /* MSIE */
    csr_set(mstatus, (1 << 3)); /* MIE */

    CLINT_MSIP = 1;  /* Trigger software interrupt */

    for (volatile int i = 0; i < 1000 && !soft_fired; i++);

    ee_printf("Test 6 - Soft IRQ: fired=%d ", soft_fired);
    if (soft_fired > 0) {
        ee_printf("PASS\n");
    } else {
        ee_printf("FAIL\n");
        errors++;
    }

    csr_clear(mstatus, (1 << 3));

    ee_printf("\n=== RESULT: %s (%d errors) ===\n",
              errors ? "FAIL" : "PASS", errors);

    if (errors == 0)
        tohost_pass();
    else
        tohost_fail(errors);

    return 0;
}
