#include "pwm.h"

static volatile uint32_t *m_pwm;

static inline uint32_t pwm_rd(uint32_t off) { return m_pwm[off / 4]; }
static inline void     pwm_wr(uint32_t off, uint32_t v) { m_pwm[off / 4] = v; }

void pwm_init(void)
{
    m_pwm = (volatile uint32_t *)pwm_base_addr;
    pwm_wr(PWM_PWMCFG,  0u);
    pwm_wr(PWM_PWMCMP0, 0u);
    pwm_wr(PWM_PWMCMP1, 0u);
    pwm_wr(PWM_PWMCMP2, 0u);
    pwm_wr(PWM_PWMCMP3, 0u);
}

void pwm_set_scale(uint8_t scale)
{
    uint32_t cfg = pwm_rd(PWM_PWMCFG);
    cfg = (cfg & ~PWM_PWMCFG_SCALE_MASK) | (scale & PWM_PWMCFG_SCALE_MASK);
    pwm_wr(PWM_PWMCFG, cfg);
}

void pwm_set_cmp(int ch, uint16_t value)
{
    if (ch < 0 || ch >= PWM_NCHANNELS) return;
    pwm_wr(PWM_PWMCMP(ch), value);
}

uint16_t pwm_get_cmp(int ch)
{
    if (ch < 0 || ch >= PWM_NCHANNELS) return 0;
    return (uint16_t)pwm_rd(PWM_PWMCMP(ch));
}

void pwm_enable(void)
{
    uint32_t cfg = pwm_rd(PWM_PWMCFG);
    cfg |= (1u << PWM_PWMCFG_ENALWAYS_SHIFT);
    pwm_wr(PWM_PWMCFG, cfg);
}

void pwm_disable(void)
{
    uint32_t cfg = pwm_rd(PWM_PWMCFG);
    cfg &= ~(1u << PWM_PWMCFG_ENALWAYS_SHIFT);
    pwm_wr(PWM_PWMCFG, cfg);
}

uint32_t pwm_get_pwms(void)
{
    return pwm_rd(PWM_PWMS);
}
