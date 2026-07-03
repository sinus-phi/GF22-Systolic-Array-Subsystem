#ifndef __GROUP2_UART_PRINT_H__
#define __GROUP2_UART_PRINT_H__

#include <stdint.h>
#include "uart.h"

static inline void group2_print_init(void)
{
  uart_init();
}

static inline void group2_print_str(const char *str)
{
  uart_print(str);
}

static inline void group2_print_char(char c)
{
  char one[2] = {c, '\0'};
  uart_print(one);
}

static inline void group2_print_i32(int32_t value)
{
  char buf[12];
  int idx = 0;

  if (value == 0) {
    group2_print_char('0');
    return;
  }

  if (value < 0) {
    group2_print_char('-');
    value = -value;
  }

  while ((value > 0) && (idx < (int)sizeof(buf))) {
    buf[idx++] = (char)('0' + (value % 10));
    value /= 10;
  }

  while (idx > 0) {
    group2_print_char(buf[--idx]);
  }
}

static inline void group2_print_hex32(uint32_t value)
{
  static const char hex[] = "0123456789abcdef";

  group2_print_str("0x");
  for (int shift = 28; shift >= 0; shift -= 4) {
    group2_print_char(hex[(value >> shift) & 0xFu]);
  }
}

static inline void group2_print_check(const char *name, int pass)
{
  group2_print_str(pass ? "[PASS] " : "[FAIL] ");
  group2_print_str(name);
  group2_print_str("\r\n");
}

static inline void group2_print_check_u32(const char *name,
                                          uint32_t expected,
                                          uint32_t actual,
                                          int *errors)
{
  int pass = (expected == actual);
  group2_print_str(pass ? "[PASS] " : "[FAIL] ");
  group2_print_str(name);
  group2_print_str(" expected=");
  group2_print_hex32(expected);
  group2_print_str(" actual=");
  group2_print_hex32(actual);
  group2_print_str("\r\n");

  if (!pass && errors) {
    *errors += 1;
  }
}

static inline void group2_print_check_i32(const char *name,
                                          int32_t expected,
                                          int32_t actual,
                                          int *errors)
{
  int pass = (expected == actual);
  group2_print_str(pass ? "[PASS] " : "[FAIL] ");
  group2_print_str(name);
  group2_print_str(" expected=");
  group2_print_i32(expected);
  group2_print_str(" actual=");
  group2_print_i32(actual);
  group2_print_str("\r\n");

  if (!pass && errors) {
    *errors += 1;
  }
}

#endif
