#include "init.h"
#include "uart.h"
#include "ee_printf.h"
#include "tohost.h"

/* Quick FPU + AMO verification test */

static volatile int amo_target = 0;

static int test_fpu(void) {
    int errors = 0;

    /* Basic arithmetic */
    volatile float a = 3.14f;
    volatile float b = 2.0f;
    volatile float c = a * b;
    if (c < 6.27f || c > 6.29f) { ee_printf("FAIL: fmul %d\n", (int)(c*100)); errors++; }

    volatile float d = a + b;
    if (d < 5.13f || d > 5.15f) { ee_printf("FAIL: fadd %d\n", (int)(d*100)); errors++; }

    volatile float e = a - b;
    if (e < 1.13f || e > 1.15f) { ee_printf("FAIL: fsub %d\n", (int)(e*100)); errors++; }

    volatile float f = a / b;
    if (f < 1.56f || f > 1.58f) { ee_printf("FAIL: fdiv %d\n", (int)(f*100)); errors++; }

    /* fsqrt */
    volatile float g = 9.0f;
    volatile float h;
    __asm__ volatile("fsqrt.s %0, %1" : "=f"(h) : "f"(g));
    if (h < 2.99f || h > 3.01f) { ee_printf("FAIL: fsqrt %d\n", (int)(h*100)); errors++; }

    /* float-to-int conversion */
    volatile float big = 12345.0f;
    int ival;
    __asm__ volatile("fcvt.w.s %0, %1, rtz" : "=r"(ival) : "f"(big));
    if (ival != 12345) { ee_printf("FAIL: fcvt.w.s %d\n", ival); errors++; }

    /* int-to-float conversion */
    int src = -42;
    volatile float fval;
    __asm__ volatile("fcvt.s.w %0, %1" : "=f"(fval) : "r"(src));
    if (fval < -42.1f || fval > -41.9f) { ee_printf("FAIL: fcvt.s.w %d\n", (int)(fval)); errors++; }

    /* fmin / fmax */
    volatile float mn, mx;
    __asm__ volatile("fmin.s %0, %1, %2" : "=f"(mn) : "f"(a), "f"(b));
    __asm__ volatile("fmax.s %0, %1, %2" : "=f"(mx) : "f"(a), "f"(b));
    if (mn < 1.99f || mn > 2.01f) { ee_printf("FAIL: fmin %d\n", (int)(mn*100)); errors++; }
    if (mx < 3.13f || mx > 3.15f) { ee_printf("FAIL: fmax %d\n", (int)(mx*100)); errors++; }

    return errors;
}

static int test_amo(void) {
    int errors = 0;
    int old;

    /* amoadd.w */
    amo_target = 100;
    __asm__ volatile("fence rw, rw\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop" ::: "memory");
    __asm__ volatile("amoadd.w %0, %1, (%2)" : "=&r"(old) : "r"(50), "r"(&amo_target) : "memory");
    if (old != 100) { ee_printf("FAIL: amoadd old=%d\n", old); errors++; }
    if (amo_target != 150) { ee_printf("FAIL: amoadd new=%d\n", amo_target); errors++; }

    /* amoswap.w */
    amo_target = 200;
    __asm__ volatile("fence rw, rw\nnop\nnop\nnop\nnop\nnop\nnop\nnop\nnop" ::: "memory");
    __asm__ volatile("amoswap.w %0, %1, (%2)" : "=&r"(old) : "r"(300), "r"(&amo_target) : "memory");
    if (old != 200) { ee_printf("FAIL: amoswap old=%d\n", old); errors++; }
    if (amo_target != 300) { ee_printf("FAIL: amoswap new=%d\n", amo_target); errors++; }

    /* amoand.w */
    amo_target = 0xFF;
    __asm__ volatile("fence rw, rw" ::: "memory");
    __asm__ volatile("amoand.w %0, %1, (%2)" : "=&r"(old) : "r"(0x0F), "r"(&amo_target) : "memory");
    if (old != 0xFF) { ee_printf("FAIL: amoand old=%d\n", old); errors++; }
    if (amo_target != 0x0F) { ee_printf("FAIL: amoand new=%d\n", amo_target); errors++; }

    /* amoor.w */
    amo_target = 0x0F;
    __asm__ volatile("fence rw, rw" ::: "memory");
    __asm__ volatile("amoor.w %0, %1, (%2)" : "=&r"(old) : "r"(0xF0), "r"(&amo_target) : "memory");
    if (old != 0x0F) { ee_printf("FAIL: amoor old=%d\n", old); errors++; }
    if (amo_target != 0xFF) { ee_printf("FAIL: amoor new=%d\n", amo_target); errors++; }

    /* lr.w / sc.w */
    amo_target = 42;
    __asm__ volatile("fence rw, rw" ::: "memory");
    int sc_result;
    __asm__ volatile(
        "lr.w %0, (%2)\n"
        "sc.w %1, %3, (%2)\n"
        : "=&r"(old), "=&r"(sc_result)
        : "r"(&amo_target), "r"(99)
        : "memory"
    );
    if (old != 42) { ee_printf("FAIL: lr.w old=%d\n", old); errors++; }
    if (sc_result != 0) { ee_printf("FAIL: sc.w failed=%d\n", sc_result); errors++; }
    if (amo_target != 99) { ee_printf("FAIL: lr/sc new=%d\n", amo_target); errors++; }

    return errors;
}

int main(void) {
    int_disable();
    uart_init(115200);

    ee_printf("\n=== FPU + AMO Verification ===\n\n");

    ee_printf("--- FPU Tests ---\n");
    int fpu_err = test_fpu();
    ee_printf("FPU: %s (%d errors)\n\n", fpu_err ? "FAIL" : "PASS", fpu_err);

    ee_printf("--- AMO Tests ---\n");
    int amo_err = test_amo();
    ee_printf("AMO: %s (%d errors)\n\n", amo_err ? "FAIL" : "PASS", amo_err);

    int total = fpu_err + amo_err;
    ee_printf("=== RESULT: %s (%d total errors) ===\n", total ? "FAIL" : "PASS", total);

    if (total == 0)
        tohost_pass();
    else
        tohost_fail(total);

    return 0;
}
