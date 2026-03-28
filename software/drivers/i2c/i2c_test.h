#ifndef __I2C_TEST_H__
#define __I2C_TEST_H__

#include "i2c.h"

#include "i2c_defs.h"
#include "test.h"
int         i2c_test();
void        send_string(char * data);
void        read_string(char *data);


#endif