#ifndef __GROUP2_SA_H__
#define __GROUP2_SA_H__

#include <stdint.h>
#include "soc_ctrl.h"

// v2 FPGA-only Group2 flow:
//   generated instance student_wrapper_2 uses module type student_wrapper_1.
//   That instance is connected to APB_2, reset/clock/IRQ bit 2.
//   On current v2 hardware, APB_2 is reachable at 0x0152_0000.  The generated
//   obi_icn_ss addr_rule idx fields look reversed, but a live FPGA diagnostic
//   read/write test confirms that the address-rule array position is what
//   selects the APB manager port.
#define GROUP2_SA_SLOT          2u
#define GROUP2_SA_BASE          0x01520000u

#define GROUP2_SA_OFF_CONTROL      0x000u
#define GROUP2_SA_OFF_STATUS       0x004u
#define GROUP2_SA_OFF_CONFIG       0x008u
#define GROUP2_SA_OFF_PROGRESS     0x00Cu
#define GROUP2_SA_OFF_ERROR_CODE   0x010u
#define GROUP2_SA_OFF_OUTPUT_WORDS 0x014u

#define GROUP2_SA_WEIGHT_BASE      0x100u
#define GROUP2_SA_ACT_BASE         0x200u
#define GROUP2_SA_OUTPUT_BASE      0x400u

#define GROUP2_SA_CTRL_LOAD_WEIGHTS   (1u << 0)
#define GROUP2_SA_CTRL_RELEASE_OUTPUT (1u << 1)
#define GROUP2_SA_CTRL_CLEAR_DONE     (1u << 2)
#define GROUP2_SA_CTRL_CLEAR_ERROR    (1u << 3)
#define GROUP2_SA_CTRL_SOFT_RESET     (1u << 4)

#define GROUP2_SA_DTYPE_INT4   0u
#define GROUP2_SA_DTYPE_INT8   1u
#define GROUP2_SA_DTYPE_INT16  2u
#define GROUP2_SA_DTYPE_INT32  3u

#define GROUP2_SA_PH_IDLE            0u
#define GROUP2_SA_PH_LOAD_WEIGHTS    1u
#define GROUP2_SA_PH_BATCH_COMPUTE   2u
#define GROUP2_SA_PH_DRAIN_WRITEBACK 3u
#define GROUP2_SA_PH_ERROR           4u

#define GROUP2_SA_ERR_NONE           0u
#define GROUP2_SA_ERR_BAD_ADDR       1u
#define GROUP2_SA_ERR_UNALIGNED      2u
#define GROUP2_SA_ERR_BAD_STATE      3u
#define GROUP2_SA_ERR_OUTPUT_RANGE   4u
#define GROUP2_SA_ERR_INVALID_CONFIG 5u
#define GROUP2_SA_ERR_FATAL_CTRL     6u

static inline void group2_sa_write32(uint32_t offset, uint32_t value)
{
  *(volatile uint32_t *)(GROUP2_SA_BASE + offset) = value;
}

static inline uint32_t group2_sa_read32(uint32_t offset)
{
  return *(volatile uint32_t *)(GROUP2_SA_BASE + offset);
}

static inline void group2_sa_enable(void)
{
  ss_init(GROUP2_SA_SLOT);
}

static inline void group2_sa_disable(void)
{
  ss_reset(GROUP2_SA_SLOT);
}

static inline uint32_t group2_sa_make_config(uint32_t act_precision,
                                             uint32_t weight_precision,
                                             uint32_t tile_m,
                                             uint32_t tile_n,
                                             uint32_t tile_k,
                                             uint32_t batch_count)
{
  return ((act_precision & 0x3u) |
          ((weight_precision & 0x3u) << 2) |
          ((tile_m & 0x1Fu) << 4) |
          ((tile_n & 0x1Fu) << 9) |
          ((tile_k & 0x1Fu) << 14) |
          ((batch_count & 0x3Fu) << 19));
}

static inline uint32_t group2_sa_status_phase(uint32_t status)
{
  return (status >> 7) & 0x7u;
}

static inline uint32_t group2_sa_status_busy(uint32_t status)
{
  return status & 0x1u;
}

static inline uint32_t group2_sa_status_error(uint32_t status)
{
  return (status >> 1) & 0x1u;
}

static inline uint32_t group2_sa_status_done(uint32_t status)
{
  return (status >> 2) & 0x1u;
}

static inline uint32_t group2_sa_status_weights_valid(uint32_t status)
{
  return (status >> 3) & 0x1u;
}

static inline uint32_t group2_sa_status_output_valid(uint32_t status)
{
  return (status >> 4) & 0x1u;
}

static inline uint32_t group2_sa_status_output_words(uint32_t status)
{
  return (status >> 16) & 0xFFu;
}

static inline void group2_sa_soft_reset(void)
{
  group2_sa_write32(GROUP2_SA_OFF_CONTROL,
                    GROUP2_SA_CTRL_SOFT_RESET |
                    GROUP2_SA_CTRL_CLEAR_DONE |
                    GROUP2_SA_CTRL_CLEAR_ERROR |
                    GROUP2_SA_CTRL_RELEASE_OUTPUT);
}

static inline int group2_sa_wait_phase(uint32_t expected_phase,
                                       uint32_t timeout_reads,
                                       uint32_t *last_status)
{
  uint32_t status = 0u;
  while (timeout_reads-- > 0u) {
    status = group2_sa_read32(GROUP2_SA_OFF_STATUS);
    if (group2_sa_status_phase(status) == expected_phase) {
      if (last_status) {
        *last_status = status;
      }
      return 0;
    }
  }

  if (last_status) {
    *last_status = status;
  }
  return -1;
}

static inline int group2_sa_wait_output_valid(uint32_t timeout_reads,
                                              uint32_t *last_status)
{
  uint32_t status = 0u;
  while (timeout_reads-- > 0u) {
    status = group2_sa_read32(GROUP2_SA_OFF_STATUS);
    if (group2_sa_status_output_valid(status)) {
      if (last_status) {
        *last_status = status;
      }
      return 0;
    }
  }

  if (last_status) {
    *last_status = status;
  }
  return -1;
}

static inline uint32_t group2_sa_precision_width(uint32_t precision)
{
  switch (precision & 0x3u) {
    case GROUP2_SA_DTYPE_INT4:  return 4u;
    case GROUP2_SA_DTYPE_INT8:  return 8u;
    case GROUP2_SA_DTYPE_INT16: return 16u;
    default:                    return 32u;
  }
}

static inline uint32_t group2_sa_elems_per_word(uint32_t precision)
{
  switch (precision & 0x3u) {
    case GROUP2_SA_DTYPE_INT4:  return 8u;
    case GROUP2_SA_DTYPE_INT8:  return 4u;
    case GROUP2_SA_DTYPE_INT16: return 2u;
    default:                    return 1u;
  }
}

static inline uint32_t group2_sa_mask_to_precision(int32_t value, uint32_t precision)
{
  uint32_t width = group2_sa_precision_width(precision);
  if (width >= 32u) {
    return (uint32_t)value;
  }
  return ((uint32_t)value) & ((1u << width) - 1u);
}

static inline uint32_t group2_sa_pack_vector_word(const int32_t *values,
                                                  uint32_t precision,
                                                  uint32_t tile_k,
                                                  uint32_t word_index)
{
  uint32_t width = group2_sa_precision_width(precision);
  uint32_t elems_per_word = group2_sa_elems_per_word(precision);
  uint32_t base = word_index * elems_per_word;
  uint32_t word = 0u;

  for (uint32_t lane = 0u; lane < elems_per_word; ++lane) {
    uint32_t k = base + lane;
    if (k >= tile_k) {
      break;
    }

    if (width == 32u) {
      word = (uint32_t)values[k];
    } else {
      word |= group2_sa_mask_to_precision(values[k], precision) << (lane * width);
    }
  }

  return word;
}

static inline uint32_t group2_sa_words_for_k(uint32_t precision, uint32_t tile_k)
{
  uint32_t elems_per_word = group2_sa_elems_per_word(precision);
  return (tile_k + elems_per_word - 1u) / elems_per_word;
}

static inline void group2_sa_stream_weight_vector(const int32_t *values,
                                                  uint32_t precision,
                                                  uint32_t tile_k)
{
  uint32_t words = group2_sa_words_for_k(precision, tile_k);
  for (uint32_t word_index = 0u; word_index < words; ++word_index) {
    group2_sa_write32(GROUP2_SA_WEIGHT_BASE,
                      group2_sa_pack_vector_word(values, precision, tile_k, word_index));
  }
}

static inline void group2_sa_stream_activation_vector(const int32_t *values,
                                                      uint32_t precision,
                                                      uint32_t tile_k)
{
  uint32_t words = group2_sa_words_for_k(precision, tile_k);
  for (uint32_t word_index = 0u; word_index < words; ++word_index) {
    group2_sa_write32(GROUP2_SA_ACT_BASE,
                      group2_sa_pack_vector_word(values, precision, tile_k, word_index));
  }
}

static inline int64_t group2_sa_read_output_elem(uint32_t row, uint32_t col, uint32_t tile_n)
{
  uint32_t word_index = ((row * tile_n) + col) * 2u;
  uint32_t low = group2_sa_read32(GROUP2_SA_OUTPUT_BASE + (word_index * 4u));
  uint32_t high = group2_sa_read32(GROUP2_SA_OUTPUT_BASE + ((word_index + 1u) * 4u));
  uint64_t bits = ((uint64_t)high << 32) | (uint64_t)low;
  return (int64_t)bits;
}

static inline void group2_sa_release_output(void)
{
  group2_sa_write32(GROUP2_SA_OFF_CONTROL,
                    GROUP2_SA_CTRL_RELEASE_OUTPUT | GROUP2_SA_CTRL_CLEAR_DONE);
}

#endif
