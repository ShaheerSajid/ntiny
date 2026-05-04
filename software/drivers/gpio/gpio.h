#ifndef GPIO_H_
#define GPIO_H_
#include <stdint.h>
#include "gpio_defs.h"

/* Bare-metal API kept stable across the Phase 2a layout change so
 * existing tests / examples keep working. Implementations now drive
 * the sifive,gpio0 register set under the hood. */

void     gpio_mode(int pin, uint8_t mode);          /* mode: 1=output, 0=input */
void     gpio_write_pin(int pin, uint8_t state);
int      gpio_read_pin(int pin);
void     gpio_reset(void);                          /* clear direction, output, irq state */
void     gpio_reset_DDR(void);                      /* clear direction (all pins -> input) */
void     gpio_reset_DOUT(void);                     /* clear output value */
void     gpio_set(uint32_t value);                  /* write output_val */
void     gpio_set_ddr(uint32_t value);              /* write output_en */
uint32_t gpio_read_all(void);                       /* read input_val */
uint32_t gpio_check_pin_mode(void);                 /* read output_en */

/* IRQ programming. Phase 2a expanded the legacy single-mode
 * gpio_set_interrupt() into per-pin per-edge/level enables. The
 * legacy entry point still exists; it now enables both rise and
 * fall edges on pin 0 to keep its old behaviour-ish. */
void     gpio_set_interrupt(void);
void     gpio_irq_enable_rise(uint32_t mask);
void     gpio_irq_enable_fall(uint32_t mask);
void     gpio_irq_enable_high(uint32_t mask);
void     gpio_irq_enable_low(uint32_t mask);
uint32_t gpio_irq_pending_rise(void);
uint32_t gpio_irq_pending_fall(void);
void     gpio_irq_clear_rise(uint32_t mask);
void     gpio_irq_clear_fall(uint32_t mask);

#endif
