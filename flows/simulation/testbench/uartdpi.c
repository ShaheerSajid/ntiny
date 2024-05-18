/**
 * SPDX-License-Identifier: Apache-2.0
 *
 * Copyright 2016 by the authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 *
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <pty.h>
#include <printf.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>

#ifdef VERILATOR_SIM
  #include "Vtb_soc_top__Dpi.h"
  #include "Vtb_soc_top.h"
  #include "verilated.h"
#endif

typedef struct {
  char ptyname[64];
  int master;
  int slave;
  char tmp_read;
} uartdpi_t;

extern void* uartdpi_create(const char *name) {
  uartdpi_t *obj = (uartdpi_t*)malloc(sizeof(uartdpi_t));

  struct termios tty;
  cfmakeraw(&tty);
  
  openpty(&obj->master, &obj->slave, 0, &tty, 0);
  int rv = ttyname_r(obj->slave, obj->ptyname, 64);
  (void) rv;
  printf("uartdpi: Create %s for %s\n", obj->ptyname, name);

  fcntl(obj->master, F_SETFL, fcntl(obj->master, F_GETFL, 0) | O_NONBLOCK);
  
  return (void*) obj;
}

extern int uartdpi_can_read(void* obj) {
  uartdpi_t *dpi = (uartdpi_t*) obj;

  int rv = read(dpi->master, &dpi->tmp_read, 1);
  return (rv == 1);
}

extern char uartdpi_read(void* obj) {
  uartdpi_t *dpi = (uartdpi_t*) obj;

  return dpi->tmp_read;
}

extern void uartdpi_write(void *obj, int data)
{
   uartdpi_t *dpi = (uartdpi_t*) obj;

  int rv = write(dpi->master, &data, 1);
  (void) rv;
}

