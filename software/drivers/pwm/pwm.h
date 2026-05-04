#ifndef __PWM_H__
#define __PWM_H__

#include <stdint.h>
#include "mem_map.h"

/* sifive,pwm0 register map. Phase 2e standardisation. */

#define PWM_PWMCFG          0x00
    #define PWM_PWMCFG_SCALE_MASK       0xfu
    #define PWM_PWMCFG_STICKY_SHIFT     8
    #define PWM_PWMCFG_ZEROCMP_SHIFT    9
    #define PWM_PWMCFG_DEGLITCH_SHIFT   10
    #define PWM_PWMCFG_ENALWAYS_SHIFT   12
    #define PWM_PWMCFG_ENONCE_SHIFT     13
    #define PWM_PWMCFG_CENTER_SHIFT     16
    #define PWM_PWMCFG_GANG_SHIFT       24
    #define PWM_PWMCFG_IP_SHIFT         28      /* bits[31:28] = ip[3:0] */

#define PWM_PWMCOUNT        0x08
#define PWM_PWMS            0x10

#define PWM_PWMCMP0         0x20
#define PWM_PWMCMP1         0x24
#define PWM_PWMCMP2         0x28
#define PWM_PWMCMP3         0x2c
#define PWM_PWMCMP(i)       (PWM_PWMCMP0 + 4u * (i))

#define PWM_NCHANNELS       4

void     pwm_init(void);
void     pwm_set_scale(uint8_t scale);          /* 0..15 */
void     pwm_set_cmp(int ch, uint16_t value);   /* ch = 0..3 */
uint16_t pwm_get_cmp(int ch);
void     pwm_enable(void);                      /* sets EN_ALWAYS */
void     pwm_disable(void);                     /* clears EN_ALWAYS */
uint32_t pwm_get_pwms(void);                    /* current scaled count */

#endif
