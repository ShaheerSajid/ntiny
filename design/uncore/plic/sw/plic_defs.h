#ifndef PLIC_DEFS_H_
#define PLIC_DEFS_H_

#include "mem_map.h"

#define   IE_INTERRUPT  0x00 //RW
#define   THRESHOLD     0x01 //RW
#define   PRIORITY      0x02 //RW
#define   INTERRUPT_ID  0x03 //RO

#endif