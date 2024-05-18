#include <time.h>
#include <stdint.h>
#include "csr.h"


clock_t clock()
{
	uint64_t cycles = csr_read(mcycleh);
  	cycles = (cycles << 32) + csr_read(mcycle);
  	return (clock_t)cycles;
}
