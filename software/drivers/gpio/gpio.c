#include "gpio.h"

/* Treat the GPIO base as a uint8_t* internally so byte offsets in
 * gpio_defs.h match the SiFive register map directly. Each access
 * goes through a 32-bit aligned cast. */
static volatile uint8_t * const gpio_base = (volatile uint8_t *)GPIO_BASE_ADDR;

static inline uint32_t gpio_rd(unsigned offset) {
    return *(volatile uint32_t *)(gpio_base + offset);
}

static inline void gpio_wr(unsigned offset, uint32_t value) {
    *(volatile uint32_t *)(gpio_base + offset) = value;
}

void gpio_mode(int pin, uint8_t mode)
{
    uint32_t v = gpio_rd(GPIO_OUTPUT_EN);
    if (mode) v |=  (1u << pin);
    else      v &= ~(1u << pin);
    gpio_wr(GPIO_OUTPUT_EN, v);
}

void gpio_write_pin(int pin, uint8_t state)
{
    uint32_t v = gpio_rd(GPIO_OUTPUT_VAL);
    if (state) v |=  (1u << pin);
    else       v &= ~(1u << pin);
    gpio_wr(GPIO_OUTPUT_VAL, v);
}

int gpio_read_pin(int pin)
{
    return (int)((gpio_rd(GPIO_INPUT_VAL) >> pin) & 1u);
}

void gpio_reset(void)
{
    /* SiFive layout has no soft-reset bit. Software clears the registers
     * we care about. IRQ pending bits are W1C, so we write all-ones. */
    gpio_wr(GPIO_OUTPUT_EN,  0);
    gpio_wr(GPIO_OUTPUT_VAL, 0);
    gpio_wr(GPIO_RISE_IE,    0);
    gpio_wr(GPIO_FALL_IE,    0);
    gpio_wr(GPIO_HIGH_IE,    0);
    gpio_wr(GPIO_LOW_IE,     0);
    gpio_wr(GPIO_RISE_IP,    0xFFFFFFFFu);
    gpio_wr(GPIO_FALL_IP,    0xFFFFFFFFu);
    gpio_wr(GPIO_HIGH_IP,    0xFFFFFFFFu);
    gpio_wr(GPIO_LOW_IP,     0xFFFFFFFFu);
}

void gpio_reset_DDR(void)  { gpio_wr(GPIO_OUTPUT_EN,  0); }
void gpio_reset_DOUT(void) { gpio_wr(GPIO_OUTPUT_VAL, 0); }

void gpio_set(uint32_t value)     { gpio_wr(GPIO_OUTPUT_VAL, value); }
void gpio_set_ddr(uint32_t value) { gpio_wr(GPIO_OUTPUT_EN,  value); }

uint32_t gpio_read_all(void)       { return gpio_rd(GPIO_INPUT_VAL); }
uint32_t gpio_check_pin_mode(void) { return gpio_rd(GPIO_OUTPUT_EN); }

/* Legacy: enable interrupts on the lowest-numbered pin. The old cmd
 * register let one global edge-mode select drive all pins; here we
 * enable both rise and fall edges on pin 0 to keep the most common
 * bring-up wiring working without a behaviour change. */
void gpio_set_interrupt(void)
{
    gpio_wr(GPIO_RISE_IE, gpio_rd(GPIO_RISE_IE) | 0x1u);
    gpio_wr(GPIO_FALL_IE, gpio_rd(GPIO_FALL_IE) | 0x1u);
}

void gpio_irq_enable_rise(uint32_t mask) { gpio_wr(GPIO_RISE_IE, gpio_rd(GPIO_RISE_IE) | mask); }
void gpio_irq_enable_fall(uint32_t mask) { gpio_wr(GPIO_FALL_IE, gpio_rd(GPIO_FALL_IE) | mask); }
void gpio_irq_enable_high(uint32_t mask) { gpio_wr(GPIO_HIGH_IE, gpio_rd(GPIO_HIGH_IE) | mask); }
void gpio_irq_enable_low (uint32_t mask) { gpio_wr(GPIO_LOW_IE,  gpio_rd(GPIO_LOW_IE)  | mask); }

uint32_t gpio_irq_pending_rise(void) { return gpio_rd(GPIO_RISE_IP); }
uint32_t gpio_irq_pending_fall(void) { return gpio_rd(GPIO_FALL_IP); }

void gpio_irq_clear_rise(uint32_t mask) { gpio_wr(GPIO_RISE_IP, mask); }
void gpio_irq_clear_fall(uint32_t mask) { gpio_wr(GPIO_FALL_IP, mask); }
