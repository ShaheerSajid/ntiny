#ifndef PLIC_H_
#define PLIC_H_
#include <stdint.h>


void set_interrupt_enable(uint32_t val);
uint32_t get_interrupt_enable();

void set_interrupt_threshold(uint32_t val);
uint32_t get_interrupt_threshold();

void set_interrupt_priority(uint32_t val);
uint32_t get_interrupt_priority();

uint32_t get_interrupt_id();

#endif