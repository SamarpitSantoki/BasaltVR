#ifndef BASALT_TEST_COLORS_H
#define BASALT_TEST_COLORS_H

#include <stdint.h>

/*
 * Deterministic per-frame RGBA8 clear color shared by the Wine-side OpenXR
 * smoke and the native control test daemon. frame_number is the runtime's
 * FrameReady number (1-based, counting successful layered xrEndFrame calls),
 * so both sides derive the same value independently. The packed u32 has
 * bytes r,g,b,255 in memory (RGBA8, little-endian), and every channel is
 * exactly representable through a float clear (n/255).
 */
static inline uint32_t basaltTestClearColor(uint64_t frame_number) {
    const uint32_t r = (uint32_t)((frame_number * 37u) % 200u) + 20u;
    const uint32_t g = (uint32_t)((frame_number * 73u) % 200u) + 20u;
    const uint32_t b = (uint32_t)((frame_number * 151u) % 200u) + 20u;
    return 0xff000000u | (b << 16) | (g << 8) | r;
}

#endif
