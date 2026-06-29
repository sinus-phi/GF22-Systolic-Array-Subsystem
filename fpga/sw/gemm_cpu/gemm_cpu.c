#include <stdint.h>
#include "uart.h"

#define M 4
#define N 4
#define K 4

static const int8_t a[M][K] = {
  { 1,  2,  3,  4},
  {-1,  0,  2,  1},
  { 3, -2,  1,  0},
  { 2,  1, -3,  2}
};

static const int8_t b[N][K] = {
  { 1,  0, -1,  2},
  { 2,  1,  0, -1},
  {-2,  3,  1,  0},
  { 0, -1,  2,  1}
};

static const int32_t bias[N] = {1, -2, 3, 0};

static const int32_t golden[M][N] = {
  {  7,  -2,  10,   8},
  {  0,  -5,   7,   5},
  {  3,   2,  -8,   4},
  { 10,   1,  -1,  -5}
};

static void print_char(char c)
{
  write_serial(c);
}

static void print_str(const char *str)
{
  uart_print(str);
}

static void print_i32(int32_t value)
{
  char buf[12];
  int idx = 0;

  if (value == 0) {
    print_char('0');
    return;
  }

  if (value < 0) {
    print_char('-');
    value = -value;
  }

  while (value > 0 && idx < (int)sizeof(buf)) {
    buf[idx++] = (char)('0' + (value % 10));
    value /= 10;
  }

  while (idx > 0) {
    print_char(buf[--idx]);
  }
}

static void print_matrix(const char *name, const int32_t matrix[M][N])
{
  print_str(name);
  print_str("\r\n");
  for (int i = 0; i < M; ++i) {
    print_str("  ");
    for (int n = 0; n < N; ++n) {
      print_i32(matrix[i][n]);
      if (n + 1 < N) {
        print_str(", ");
      }
    }
    print_str("\r\n");
  }
}

int main(void)
{
  int32_t c[M][N];
  int errors = 0;

  uart_init(25000000, 9600);
  print_str("\r\nCPU-only GEMM test on Didactic RISC-V\r\n");
  print_str("Shape: M=4 N=4 K=4, SS/accelerator not used\r\n");

  for (int i = 0; i < M; ++i) {
    for (int n = 0; n < N; ++n) {
      int32_t sum = bias[n];
      for (int k = 0; k < K; ++k) {
        sum += (int32_t)a[i][k] * (int32_t)b[n][k];
      }
      c[i][n] = sum;
      if (sum != golden[i][n]) {
        errors++;
      }
    }
  }

  print_matrix("C result:", c);
  print_matrix("Golden:", golden);

  if (errors == 0) {
    print_str("GEMM CPU TEST PASS\r\n");
  } else {
    print_str("GEMM CPU TEST FAIL mismatches=");
    print_i32(errors);
    print_str("\r\n");
  }

  while (1) {
  }
}
