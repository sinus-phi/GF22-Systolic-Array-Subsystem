#include <stdint.h>
#include "group2_sa.h"
#include "group2_uart_print.h"

#define TILE_M 2u
#define TILE_N 3u
#define TILE_K 4u

static const int32_t acts[TILE_M][TILE_K] = {
  { 3,  4, -1,  2},
  {-1,  2,  5, -3}
};

static const int32_t weights[TILE_N][TILE_K] = {
  { 1, -1,  2, -2},
  { 0,  3, -1,  1},
  {-2,  1,  0,  2}
};

static const int32_t golden[TILE_M][TILE_N] = {
  { -7, 15,  2},
  { 13, -2, -2}
};

static void short_delay(void)
{
  for (volatile uint32_t i = 0; i < 1000u; ++i) {
    asm volatile("nop");
  }
}

static void print_matrix_row(uint32_t row, const int32_t *values, uint32_t cols)
{
  group2_print_str("  row ");
  group2_print_i32((int32_t)row);
  group2_print_str(": ");
  for (uint32_t col = 0u; col < cols; ++col) {
    group2_print_i32(values[col]);
    if ((col + 1u) < cols) {
      group2_print_str(", ");
    }
  }
  group2_print_str("\r\n");
}

int main(void)
{
  int errors = 0;
  uint32_t status = 0u;
  int32_t got[TILE_M][TILE_N];

  group2_print_init();
  group2_print_str("\r\nGROUP2 GEMM test: INT4 A[2x4] x W[3x4]^T\r\n");

  group2_sa_disable();
  short_delay();
  group2_sa_enable();
  short_delay();
  group2_sa_soft_reset();

  uint32_t cfg = group2_sa_make_config(GROUP2_SA_DTYPE_INT4,
                                       GROUP2_SA_DTYPE_INT4,
                                       TILE_M,
                                       0u);
  group2_sa_write32(GROUP2_SA_OFF_CONFIG, cfg);
  group2_sa_write32(GROUP2_SA_OFF_CONTROL, GROUP2_SA_CTRL_START_GEMM);

  if (group2_sa_wait_phase(GROUP2_SA_PH_WEIGHT, 2000u, &status) != 0) {
    group2_print_str("[FAIL] load weight phase timeout status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    errors++;
  }

  for (uint32_t n = 0u; n < TILE_N; ++n) {
    group2_sa_stream_weight_vector(weights[n], GROUP2_SA_DTYPE_INT4, TILE_K);
  }
  const int32_t zero_weight[GROUP2_SA_K_TILE] = {0};
  for (uint32_t n = TILE_N; n < GROUP2_SA_LOGICAL_N; ++n) {
    group2_sa_stream_weight_vector(zero_weight, GROUP2_SA_DTYPE_INT4,
                                   GROUP2_SA_K_TILE);
  }

  if (group2_sa_wait_phase(GROUP2_SA_PH_ACTIVATION, 4000u, &status) != 0) {
    group2_print_str("[FAIL] compute phase timeout status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    errors++;
  }

  for (uint32_t m = 0u; m < TILE_M; ++m) {
    group2_sa_stream_activation_vector(acts[m], GROUP2_SA_DTYPE_INT4, TILE_K);
  }

  if (group2_sa_wait_output(8000u, &status) != 0) {
    group2_print_str("[FAIL] output valid timeout status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    errors++;
  } else {
    group2_print_check_u32("output word count",
                           TILE_M * GROUP2_SA_OUTPUT_WORDS_PER_ROW,
                           group2_sa_output_words(),
                           &errors);

    for (uint32_t m = 0u; m < TILE_M; ++m) {
      for (uint32_t pair = 0u; pair < (TILE_N + 1u) / 2u; ++pair) {
        uint32_t word = group2_sa_read_output_word(m, pair);
        uint32_t col = pair * 2u;
        got[m][col] = (int32_t)group2_sa_output_word_low(word);
        if (col + 1u < TILE_N) {
          got[m][col + 1u] = (int32_t)group2_sa_output_word_high(word);
        }
      }
    }

    group2_print_str("Observed C:\r\n");
    for (uint32_t m = 0u; m < TILE_M; ++m) {
      print_matrix_row(m, got[m], TILE_N);
    }

    for (uint32_t m = 0u; m < TILE_M; ++m) {
      for (uint32_t n = 0u; n < TILE_N; ++n) {
        char name[] = "C[0][0]";
        name[2] = (char)('0' + m);
        name[5] = (char)('0' + n);
        group2_print_check_i32(name, golden[m][n], got[m][n], &errors);
      }
    }
  }

  group2_sa_release_context();
  if (group2_sa_wait_phase(GROUP2_SA_PH_IDLE, 4000u, &status) != 0) {
    group2_print_str("[FAIL] idle after release timeout status=");
    group2_print_hex32(status);
    group2_print_str("\r\n");
    errors++;
  }

  if (errors == 0) {
    group2_print_str("GROUP2 GEMM TEST PASS\r\n");
  } else {
    group2_print_str("GROUP2 GEMM TEST FAIL errors=");
    group2_print_i32(errors);
    group2_print_str("\r\n");
  }

  while (1) {
  }
}
