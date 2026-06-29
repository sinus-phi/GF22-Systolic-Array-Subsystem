#include <stdint.h>
#include "ss2_sa.h"
#include "ss2_uart_print.h"

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
  ss2_print_str("  row ");
  ss2_print_i32((int32_t)row);
  ss2_print_str(": ");
  for (uint32_t col = 0u; col < cols; ++col) {
    ss2_print_i32(values[col]);
    if ((col + 1u) < cols) {
      ss2_print_str(", ");
    }
  }
  ss2_print_str("\r\n");
}

int main(void)
{
  int errors = 0;
  uint32_t status = 0u;
  int32_t got[TILE_M][TILE_N];

  ss2_print_init();
  ss2_print_str("\r\nSS2 GEMM test: INT4 A[2x4] x W[3x4]^T\r\n");

  ss2_sa_disable();
  short_delay();
  ss2_sa_enable();
  short_delay();
  ss2_sa_soft_reset();

  uint32_t cfg = ss2_sa_make_config(SS2_SA_DTYPE_INT4,
                                    SS2_SA_DTYPE_INT4,
                                    TILE_M,
                                    TILE_N,
                                    TILE_K,
                                    1u);
  ss2_sa_write32(SS2_SA_OFF_CONFIG, cfg);
  ss2_sa_write32(SS2_SA_OFF_CONTROL, SS2_SA_CTRL_LOAD_WEIGHTS);

  if (ss2_sa_wait_phase(SS2_SA_PH_LOAD_WEIGHTS, 2000u, &status) != 0) {
    ss2_print_str("[FAIL] load weight phase timeout status=");
    ss2_print_hex32(status);
    ss2_print_str("\r\n");
    errors++;
  }

  for (uint32_t n = 0u; n < TILE_N; ++n) {
    ss2_sa_stream_weight_vector(weights[n], SS2_SA_DTYPE_INT4, TILE_K);
  }

  if (ss2_sa_wait_phase(SS2_SA_PH_BATCH_COMPUTE, 4000u, &status) != 0) {
    ss2_print_str("[FAIL] compute phase timeout status=");
    ss2_print_hex32(status);
    ss2_print_str("\r\n");
    errors++;
  } else {
    ss2_print_check_u32("weights valid", 1u, ss2_sa_status_weights_valid(status), &errors);
  }

  for (uint32_t m = 0u; m < TILE_M; ++m) {
    ss2_sa_stream_activation_vector(acts[m], SS2_SA_DTYPE_INT4, TILE_K);
  }

  if (ss2_sa_wait_output_valid(8000u, &status) != 0) {
    ss2_print_str("[FAIL] output valid timeout status=");
    ss2_print_hex32(status);
    ss2_print_str("\r\n");
    errors++;
  } else {
    ss2_print_check_u32("output word count",
                        TILE_M * TILE_N * 2u,
                        ss2_sa_status_output_words(status),
                        &errors);

    for (uint32_t m = 0u; m < TILE_M; ++m) {
      for (uint32_t n = 0u; n < TILE_N; ++n) {
        got[m][n] = (int32_t)ss2_sa_read_output_elem(m, n, TILE_N);
      }
    }

    ss2_print_str("Observed C:\r\n");
    for (uint32_t m = 0u; m < TILE_M; ++m) {
      print_matrix_row(m, got[m], TILE_N);
    }

    for (uint32_t m = 0u; m < TILE_M; ++m) {
      for (uint32_t n = 0u; n < TILE_N; ++n) {
        char name[] = "C[0][0]";
        name[2] = (char)('0' + m);
        name[5] = (char)('0' + n);
        ss2_print_check_i32(name, golden[m][n], got[m][n], &errors);
      }
    }
  }

  ss2_sa_release_output();
  if (ss2_sa_wait_phase(SS2_SA_PH_IDLE, 4000u, &status) != 0) {
    ss2_print_str("[FAIL] idle after release timeout status=");
    ss2_print_hex32(status);
    ss2_print_str("\r\n");
    errors++;
  }

  if (errors == 0) {
    ss2_print_str("SS2 GEMM TEST PASS\r\n");
  } else {
    ss2_print_str("SS2 GEMM TEST FAIL errors=");
    ss2_print_i32(errors);
    ss2_print_str("\r\n");
  }

  while (1) {
  }
}
