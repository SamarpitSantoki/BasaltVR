#ifndef BASALT_IOSURFACE_PIXEL_PATTERN_H
#define BASALT_IOSURFACE_PIXEL_PATTERN_H

/*
 * Shared between the Wine-side pixel source (dxmt_iosurface_pixel_source.cpp)
 * and the native readback tool (native/iosurface_readback.c) for the
 * cross-process zero-copy proof in docs/DXMT-INTEROP.md (acceptance test 2).
 *
 * DXGI_FORMAT_R8G8B8A8_UNORM and the IOSurface 'RGBA' pixel format share the
 * same R,G,B,A byte order; both sides are little-endian, so the u32 values
 * below describe identical bytes in texture and surface memory. The pattern
 * is asymmetric in row and column so a pitch or transpose bug cannot pass.
 */

#include <stdint.h>

#define BASALT_PIXEL_PATTERN_WIDTH 4u
#define BASALT_PIXEL_PATTERN_HEIGHT 4u

static const uint32_t kBasaltPixelPattern[BASALT_PIXEL_PATTERN_HEIGHT]
                                         [BASALT_PIXEL_PATTERN_WIDTH] = {
    {0xff0000a5u, 0xff0001a5u, 0xff0002a5u, 0xff0003a5u},
    {0xff0100a5u, 0xff0101a5u, 0xff0102a5u, 0xff0103a5u},
    {0xff0200a5u, 0xff0201a5u, 0xff0202a5u, 0xff0203a5u},
    {0xff0300a5u, 0xff0301a5u, 0xff0302a5u, 0xff0303a5u},
};

#endif
