#include <windows.h>

#include <d3d11_1.h>
#include <dxgi1_2.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// Acceptance test 1 from docs/DXMT-INTEROP.md. Creates NT-handle-shared
// textures and inspects the Basalt fork's GetPrivateData republish:
//
//   BASALT_EXPECT_IOSURFACE=1  requires a nonzero, per-texture-distinct
//                              IOSurfaceID under BASALT_GUID_IOSURFACE_ID
//                              (forked DXMT with DXMT_BASALT_IOSURFACE=1).
//   otherwise                  requires the GUID to be absent (stock DXMT,
//                              or the fork with its gate off).

namespace {

// Must match BASALT_GUID_IOSURFACE_ID in the DXMT fork.
// {DD807311-529E-4856-A5C0-48BED2048129}
constexpr GUID kBasaltIOSurfaceIdGuid = {
    0xdd807311, 0x529e, 0x4856, {0xa5, 0xc0, 0x48, 0xbe, 0xd2, 0x04, 0x81, 0x29}};

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

HRESULT createSharedTexture(ID3D11Device* device, uint32_t width, uint32_t height,
                            ID3D11Texture2D** texture) {
    D3D11_TEXTURE2D_DESC description{};
    description.Width = width;
    description.Height = height;
    description.MipLevels = 1;
    description.ArraySize = 1;
    description.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    description.SampleDesc.Count = 1;
    description.Usage = D3D11_USAGE_DEFAULT;
    description.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    description.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE;
    return device->CreateTexture2D(&description, nullptr, texture);
}

}  // namespace

int main() {
    const char* expectVariable = std::getenv("BASALT_EXPECT_IOSURFACE");
    const bool expectPresent = expectVariable != nullptr && std::strcmp(expectVariable, "1") == 0;

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
    ID3D11Texture2D* firstTexture = nullptr;
    ID3D11Texture2D* secondTexture = nullptr;

    do {
        result = createSharedTexture(device, 4, 4, &firstTexture);
        if (FAILED(result)) {
            exitCode = fail("CreateTexture2D(first shared)", result);
            break;
        }
        result = createSharedTexture(device, 8, 8, &secondTexture);
        if (FAILED(result)) {
            exitCode = fail("CreateTexture2D(second shared)", result);
            break;
        }

        uint32_t firstId = 0;
        uint32_t secondId = 0;
        UINT firstSize = sizeof(firstId);
        UINT secondSize = sizeof(secondId);
        const HRESULT firstQuery =
            firstTexture->GetPrivateData(kBasaltIOSurfaceIdGuid, &firstSize, &firstId);
        const HRESULT secondQuery =
            secondTexture->GetPrivateData(kBasaltIOSurfaceIdGuid, &secondSize, &secondId);

        if (expectPresent) {
            if (FAILED(firstQuery) || FAILED(secondQuery)) {
                std::fprintf(stderr,
                             "FAIL: BASALT_GUID_IOSURFACE_ID absent under the fork gate "
                             "(HRESULTs 0x%08lx, 0x%08lx)\n",
                             static_cast<unsigned long>(firstQuery),
                             static_cast<unsigned long>(secondQuery));
                exitCode = 1;
                break;
            }
            if (firstSize != sizeof(firstId) || secondSize != sizeof(secondId)) {
                std::fprintf(stderr,
                             "FAIL: unexpected private-data sizes %u and %u\n",
                             firstSize, secondSize);
                exitCode = 1;
                break;
            }
            if (firstId == 0 || secondId == 0 || firstId == secondId) {
                std::fprintf(stderr,
                             "FAIL: IOSurfaceIDs not nonzero and distinct (%u, %u)\n",
                             firstId, secondId);
                exitCode = 1;
                break;
            }
            std::printf(
                "PASS: IOSurface-backed shared textures republish distinct IDs (%u, %u)\n",
                firstId, secondId);
        } else {
            if (SUCCEEDED(firstQuery) || SUCCEEDED(secondQuery)) {
                std::fprintf(stderr,
                             "FAIL: BASALT_GUID_IOSURFACE_ID present without the fork gate "
                             "(ids %u, %u)\n",
                             firstId, secondId);
                exitCode = 1;
                break;
            }
            std::printf("PASS: no IOSurface private data without the fork gate\n");
        }
    } while (false);

    release(secondTexture);
    release(firstTexture);
    release(context);
    release(device);
    return exitCode;
}
