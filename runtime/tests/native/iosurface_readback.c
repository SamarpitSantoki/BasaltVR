/*
 * Native side of the cross-process zero-copy proof (docs/DXMT-INTEROP.md,
 * acceptance test 2). Looks up the IOSurface that a Wine process created
 * through the Basalt DXMT fork and verifies the pixel pattern rendered by
 * D3D11 is readable, byte for byte, without any copy through Wine.
 *
 * Usage: iosurface_readback <IOSurfaceID>
 *
 * Built and run by test-dxmt.zsh on the host (not under Wine).
 */

#include <IOSurface/IOSurfaceRef.h>

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../iosurface_pixel_pattern.h"

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <IOSurfaceID>\n", argv[0]);
        return 2;
    }

    char* end = NULL;
    const unsigned long parsed = strtoul(argv[1], &end, 10);
    if (end == argv[1] || *end != '\0' || parsed == 0 || parsed > UINT32_MAX) {
        fprintf(stderr, "FAIL: invalid IOSurfaceID '%s'\n", argv[1]);
        return 2;
    }

    IOSurfaceRef surface = IOSurfaceLookup((IOSurfaceID)parsed);
    if (surface == NULL) {
        fprintf(stderr, "FAIL: IOSurfaceLookup(%lu) found nothing\n", parsed);
        return 1;
    }

    int exitCode = 0;
    const size_t width = IOSurfaceGetWidth(surface);
    const size_t height = IOSurfaceGetHeight(surface);
    const OSType format = IOSurfaceGetPixelFormat(surface);
    if (width != BASALT_PIXEL_PATTERN_WIDTH || height != BASALT_PIXEL_PATTERN_HEIGHT ||
        format != 'RGBA') {
        fprintf(stderr,
                "FAIL: surface is %zux%zu format 0x%08x, expected %ux%u 'RGBA'\n",
                width, height, (unsigned int)format,
                BASALT_PIXEL_PATTERN_WIDTH, BASALT_PIXEL_PATTERN_HEIGHT);
        CFRelease(surface);
        return 1;
    }

    kern_return_t lockResult = IOSurfaceLock(surface, kIOSurfaceLockReadOnly, NULL);
    if (lockResult != KERN_SUCCESS) {
        fprintf(stderr, "FAIL: IOSurfaceLock returned %d\n", lockResult);
        CFRelease(surface);
        return 1;
    }

    const uint8_t* base = (const uint8_t*)IOSurfaceGetBaseAddress(surface);
    const size_t bytesPerRow = IOSurfaceGetBytesPerRow(surface);
    for (uint32_t row = 0; row < BASALT_PIXEL_PATTERN_HEIGHT; ++row) {
        const uint8_t* actual = base + (size_t)row * bytesPerRow;
        const uint8_t* expected = (const uint8_t*)kBasaltPixelPattern[row];
        if (memcmp(actual, expected, BASALT_PIXEL_PATTERN_WIDTH * sizeof(uint32_t)) != 0) {
            const uint32_t* actualPixels = (const uint32_t*)actual;
            fprintf(stderr,
                    "FAIL: row %u mismatch: got 0x%08" PRIx32 " 0x%08" PRIx32
                    " 0x%08" PRIx32 " 0x%08" PRIx32 "\n",
                    row, actualPixels[0], actualPixels[1], actualPixels[2], actualPixels[3]);
            exitCode = 1;
            break;
        }
    }

    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, NULL);
    CFRelease(surface);

    if (exitCode == 0) {
        printf("PASS: native IOSurface readback matches the D3D11-rendered pattern\n");
    }
    return exitCode;
}
