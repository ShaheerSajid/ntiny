#include "pwm_test.h"
#include "pwm.h"
#include "uart.h"
#include "ee_printf.h"

static volatile uint32_t *m_pwm = (volatile uint32_t *)pwm_base_addr;

static int walk_cmp(uint8_t off, const char *name)
{
    /* CMP registers are 16-bit; walk a single bit through bits[15:0]. */
    for (uint32_t i = 0; i < 16; i++) {
        uint32_t v = (1u << i);
        m_pwm[off / 4] = v;
        uint32_t rb = m_pwm[off / 4] & 0xffffu;
        if (rb != v) {
            ee_printf("PWM %s walk fail at bit %u (wrote %x got %x)\n",
                      name, i, v, rb);
            return 1;
        }
    }
    m_pwm[off / 4] = 0;
    return 0;
}

int pwm_test(void)
{
    pwm_init();

    /* CFG.scale: walk a single bit through bits[3:0]. */
    for (uint32_t i = 0; i < 4; i++) {
        uint32_t v = (1u << i);
        m_pwm[PWM_PWMCFG / 4] = v;
        uint32_t rb = m_pwm[PWM_PWMCFG / 4] & PWM_PWMCFG_SCALE_MASK;
        if (rb != v) {
            ee_printf("PWM CFG.scale fail at bit %u (wrote %x got %x)\n", i, v, rb);
            return 1;
        }
    }
    m_pwm[PWM_PWMCFG / 4] = 0;

    /* CMP0..CMP3 walking-1 R/W. */
    if (walk_cmp(PWM_PWMCMP0, "CMP0")) return 1;
    if (walk_cmp(PWM_PWMCMP1, "CMP1")) return 1;
    if (walk_cmp(PWM_PWMCMP2, "CMP2")) return 1;
    if (walk_cmp(PWM_PWMCMP3, "CMP3")) return 1;

    /* CFG.enable + counter advance check. With scale=0, the counter
     * increments every cycle; pwms (the scaled count, low 16 bits)
     * must change between two reads. */
    pwm_init();
    pwm_set_scale(0);
    pwm_enable();
    uint32_t s0 = pwm_get_pwms();
    /* short busy loop to let the counter tick */
    for (volatile int i = 0; i < 200; i++) ;
    uint32_t s1 = pwm_get_pwms();
    pwm_disable();
    if (s0 == s1) {
        ee_printf("PWM counter not advancing (s0=%x s1=%x)\n", s0, s1);
        return 1;
    }

    /* CMP-match output: cmp[0] = 0x4000 should set ip[0] sticky once
     * pwms reaches 0x4000. With sticky=0 the bit follows live; with
     * sticky=1 it latches. We test the live (sticky=0) path. */
    pwm_init();
    pwm_set_cmp(0, 0x4000);
    pwm_enable();
    /* Spin until ip[0] asserts in CFG (live mode). */
    int saw_ip = 0;
    for (int i = 0; i < 200000; i++) {
        if (m_pwm[PWM_PWMCFG / 4] & (1u << (PWM_PWMCFG_IP_SHIFT + 0))) {
            saw_ip = 1;
            break;
        }
    }
    pwm_disable();
    if (!saw_ip) {
        uart_puts("PWM cmp[0] ip never asserted\n");
        return 1;
    }

    return 0;
}
