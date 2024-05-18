#include "plic.h"
#include "plic_defs.h"

volatile uint32_t *plic_base_addr = (volatile uint32_t *)PLIC_BASE_ADDR;
 

void set_interrupt_enable(uint32_t val)
{
  plic_base_addr[IE_INTERRUPT] = val & 0x1f;
}
uint32_t get_interrupt_enable()
{
  return  plic_base_addr[IE_INTERRUPT];
}

void set_interrupt_threshold(uint32_t val)
{
  plic_base_addr[THRESHOLD] = val & 0x03;
}
uint32_t get_interrupt_threshold()
{
  return plic_base_addr[THRESHOLD];
}

void set_interrupt_priority(uint32_t val)
{
  plic_base_addr[PRIORITY] = val & 0x7FFF;
}
uint32_t get_interrupt_priority()
{
  return plic_base_addr[PRIORITY];
}

uint32_t get_interrupt_id()
{
  return plic_base_addr[INTERRUPT_ID];
}