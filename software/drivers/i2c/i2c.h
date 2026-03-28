#ifndef __I2C_H__
#define __I2C_H__

#include <stdint.h>
void I2C_init ( uint32_t i2c_freq);
void I2C_close(void );
void I2C_start (uint32_t slave_addr, uint32_t read);
void I2C_write(uint8_t data,uint8_t last);
int I2C_read(uint8_t last  );

#endif