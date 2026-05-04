// ── ntiny PWM register map (sifive,pwm0 layout) ────────────────────
//
// Phase 2e peripheral standardisation: register offsets and bit fields
// match the upstream Linux SiFive PWM driver (drivers/pwm/pwm-sifive.c).
//
// Single 31-bit free-running counter + 4 compare channels. ZERO_CMP
// resets the counter when channel-0 fires (gives variable period).
// Output i is HIGH while the scaled count `pwms` < cmp[i], LOW
// otherwise — pwmcmp_ip[i] is the sticky form of the same comparison.

`define PWM_PWMCFG       8'h00
    `define PWM_PWMCFG_SCALE_R     3:0
    `define PWM_PWMCFG_STICKY_B    8
    `define PWM_PWMCFG_ZEROCMP_B   9
    `define PWM_PWMCFG_DEGLITCH_B  10
    `define PWM_PWMCFG_ENALWAYS_B  12
    `define PWM_PWMCFG_ENONCE_B    13
    `define PWM_PWMCFG_CENTER_B    16
    `define PWM_PWMCFG_GANG_B      24
    `define PWM_PWMCFG_IP0_B       28
    `define PWM_PWMCFG_IP1_B       29
    `define PWM_PWMCFG_IP2_B       30
    `define PWM_PWMCFG_IP3_B       31

`define PWM_PWMCOUNT     8'h08
`define PWM_PWMS         8'h10

`define PWM_PWMCMP0      8'h20
`define PWM_PWMCMP1      8'h24
`define PWM_PWMCMP2      8'h28
`define PWM_PWMCMP3      8'h2c
