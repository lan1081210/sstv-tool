/* SPDX-License-Identifier: GPL-3.0-only */
/* image_out.h -- PNG writer for decoded RGB565 pictures (ImageIO). */
#ifndef APRICOT_IMAGE_OUT_H
#define APRICOT_IMAGE_OUT_H

#include <stdint.h>

/* Write RGB565 (row-major) as PNG. scale > 1 replicates pixels (nearest).
 * Creates parent directories are NOT created; returns 0 on success. */
int png_write_565(const char *path, const uint16_t *px, int w, int h, int scale);

/* Write 8-bit RGB (3 bytes/pixel) as PNG. */
int png_write_rgb(const char *path, const uint8_t *rgb, int w, int h, int scale);

#endif
