#include <windows.h>

#include <d3d11_4.h>
#include <dxgi1_2.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "iosurface_pixel_pattern.h"

// Wine side of the cross-process zero-copy proof (docs/DXMT-INTEROP.md,
// acceptance test 2). Under the forked DXMT with DXMT_BASALT_IOSURFACE=1:
// renders the shared pattern into a gated NT-handle texture, waits a fence so
// the frame-done contract holds, prints the texture's global IOSurfaceID as
//   BASALT_IOSURFACE_ID=<id>
// and keeps the texture alive until the file named by BASALT_DONE_FILE
// appears (the harness creates it after the native readback), so the surface
// cannot be recycled while the other process maps it.

namespace {

// Must match BASALT_GUID_IOSURFACE_ID in the Basalt DXMT fork.
// {DD807311-529E-4856-A5C0-48BED2048129}
constexpr GUID kBasaltIOSurfaceIdGuid = {
    0xdd807311, 0x529e, 0x4856, {0xa5, 0xc0, 0x48, 0xbe, 0xd2, 0x04, 0x81, 0x29}};

constexpr DWORD kFenceWaitMilliseconds = 10000;
constexpr DWORD kDoneFileWaitMilliseconds = 60000;

template <typename Interface>
void release(Interface*& object) {
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

int fail(const char* operation, HRESULT result) {
    std::fprintf(
        stderr,
        "FAIL: %s returned HRESULT 0x%08lx\n",
        operation,
        static_cast<unsigned long>(result));
    return 1;
}

}  // namespace

int main() {
    const char* doneFile = std::getenv("BASALT_DONE_FILE");
    if (doneFile == nullptr || doneFile[0] == '\0') {
        std::fprintf(stderr, "FAIL: BASALT_DONE_FILE is not set\n");
        return 1;
    }

    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    D3D_FEATURE_LEVEL selectedFeatureLevel{};
    const D3D_FEATURE_LEVEL requestedFeatureLevels[] = {
        D3D_FEATURE_LEVEL_11_0,
    };

    HRESULT result = D3D11CreateDevice(
        nullptr,
        D3D_DRIVER_TYPE_HARDWARE,
        nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        requestedFeatureLevels,
        static_cast<UINT>(sizeof(requestedFeatureLevels) / sizeof(requestedFeatureLevels[0])),
        D3D11_SDK_VERSION,
        &device,
        &selectedFeatureLevel,
        &context);
    if (FAILED(result)) {
        return fail("D3D11CreateDevice", result);
    }

    int exitCode = 0;
    ID3D11Texture2D* texture = nullptr;
    ID3D11Device5* device5 = nullptr;
    ID3D11DeviceContext4* context4 = nullptr;
    ID3D11Fence* fence = nullptr;
    HANDLE frameEvent = nullptr;

    do {
        D3D11_TEXTURE2D_DESC description{};
        description.Width = BASALT_PIXEL_PATTERN_WIDTH;
        description.Height = BASALT_PIXEL_PATTERN_HEIGHT;
        description.MipLevels = 1;
        description.ArraySize = 1;
        description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        description.SampleDesc.Count = 1;
        description.Usage = D3D11_USAGE_DEFAULT;
        description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        description.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE;

        result = device->CreateTexture2D(&description, nullptr, &texture);
        if (FAILED(result)) {
            exitCode = fail("CreateTexture2D(gated shared)", result);
            break;
        }

        // Upload through the immediate context, not initial data: the fence
        // below signals the same queue, so its completion covers this write
        // exactly like a game's per-frame rendering.
        context->UpdateSubresource(
            texture, 0, nullptr, kBasaltPixelPattern,
            BASALT_PIXEL_PATTERN_WIDTH * sizeof(uint32_t), 0);

        uint32_t iosurfaceId = 0;
        UINT iosurfaceIdSize = sizeof(iosurfaceId);
        result = texture->GetPrivateData(kBasaltIOSurfaceIdGuid, &iosurfaceIdSize, &iosurfaceId);
        if (FAILED(result) || iosurfaceIdSize != sizeof(iosurfaceId) || iosurfaceId == 0) {
            exitCode = fail("GetPrivateData(BASALT_GUID_IOSURFACE_ID)", result);
            break;
        }

        // Frame-done contract before publishing the ID (Phase 1 in
        // docs/DXMT-INTEROP.md): fence signal after the queued upload, CPU
        // wait on completion.
        result = device->QueryInterface(IID_ID3D11Device5, reinterpret_cast<void**>(&device5));
        if (FAILED(result)) {
            exitCode = fail("QueryInterface(ID3D11Device5)", result);
            break;
        }
        result = context->QueryInterface(IID_ID3D11DeviceContext4,
                                         reinterpret_cast<void**>(&context4));
        if (FAILED(result)) {
            exitCode = fail("QueryInterface(ID3D11DeviceContext4)", result);
            break;
        }
        result = device5->CreateFence(0, D3D11_FENCE_FLAG_NONE, IID_ID3D11Fence,
                                      reinterpret_cast<void**>(&fence));
        if (FAILED(result)) {
            exitCode = fail("ID3D11Device5::CreateFence", result);
            break;
        }
        frameEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (frameEvent == nullptr) {
            exitCode = fail("CreateEventW", HRESULT_FROM_WIN32(GetLastError()));
            break;
        }
        result = fence->SetEventOnCompletion(1, frameEvent);
        if (FAILED(result)) {
            exitCode = fail("ID3D11Fence::SetEventOnCompletion", result);
            break;
        }
        result = context4->Signal(fence, 1);
        if (FAILED(result)) {
            exitCode = fail("ID3D11DeviceContext4::Signal", result);
            break;
        }
        context->Flush();
        const DWORD waitStatus = WaitForSingleObject(frameEvent, kFenceWaitMilliseconds);
        if (waitStatus != WAIT_OBJECT_0) {
            std::fprintf(stderr, "FAIL: fence wait returned %lu\n",
                         static_cast<unsigned long>(waitStatus));
            exitCode = 1;
            break;
        }

        std::printf("BASALT_IOSURFACE_ID=%u\n", iosurfaceId);
        std::fflush(stdout);

        // Hold every reference until the harness confirms the native
        // readback, then exit; polling a file avoids Wine stdin plumbing.
        bool done = false;
        for (DWORD waited = 0; waited < kDoneFileWaitMilliseconds; waited += 100) {
            if (GetFileAttributesA(doneFile) != INVALID_FILE_ATTRIBUTES) {
                done = true;
                break;
            }
            Sleep(100);
        }
        if (!done) {
            std::fprintf(stderr, "FAIL: timed out waiting for %s\n", doneFile);
            exitCode = 1;
            break;
        }
    } while (false);

    if (frameEvent != nullptr) {
        CloseHandle(frameEvent);
    }
    release(fence);
    release(context4);
    release(device5);
    release(texture);
    release(context);
    release(device);

    if (exitCode == 0) {
        std::printf("PASS: pixel source held the IOSurface until readback completed\n");
    }
    return exitCode;
}
