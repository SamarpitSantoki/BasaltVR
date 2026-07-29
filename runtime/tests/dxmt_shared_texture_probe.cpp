#include <windows.h>

#include <d3d11_1.h>
#include <dxgi1_2.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace {

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
        "FAIL: %s returned HRESULT 0x%08lx\n"
        "This probe requires Wine 10.18+ with a pinned DXMT shared-resource build.\n",
        operation,
        static_cast<unsigned long>(result));
    return 1;
}

}  // namespace

int main() {
    constexpr uint32_t kWidth = 4;
    constexpr uint32_t kHeight = 4;
    constexpr uint32_t kPixels[kWidth * kHeight] = {
        0xff030201, 0xff060504, 0xff090807, 0xff0c0b0a,
        0xff131211, 0xff161514, 0xff191817, 0xff1c1b1a,
        0xff232221, 0xff262524, 0xff292827, 0xff2c2b2a,
        0xff333231, 0xff363534, 0xff393837, 0xff3c3b3a,
    };

    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    D3D_FEATURE_LEVEL selectedFeatureLevel{};
    const D3D_FEATURE_LEVEL requestedFeatureLevels[] = {
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
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

    ID3D11Device1* device1 = nullptr;
    result = device->QueryInterface(IID_ID3D11Device1, reinterpret_cast<void**>(&device1));
    if (FAILED(result)) {
        release(context);
        release(device);
        return fail("QueryInterface(ID3D11Device1)", result);
    }

    D3D11_TEXTURE2D_DESC sharedDescription{};
    sharedDescription.Width = kWidth;
    sharedDescription.Height = kHeight;
    sharedDescription.MipLevels = 1;
    sharedDescription.ArraySize = 1;
    sharedDescription.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sharedDescription.SampleDesc.Count = 1;
    sharedDescription.Usage = D3D11_USAGE_DEFAULT;
    sharedDescription.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    sharedDescription.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE;

    D3D11_SUBRESOURCE_DATA initialData{};
    initialData.pSysMem = kPixels;
    initialData.SysMemPitch = kWidth * sizeof(uint32_t);

    ID3D11Texture2D* sharedTexture = nullptr;
    result = device->CreateTexture2D(&sharedDescription, &initialData, &sharedTexture);
    if (FAILED(result)) {
        release(device1);
        release(context);
        release(device);
        return fail("CreateTexture2D(SHARED_NTHANDLE)", result);
    }

    IDXGIResource1* sharedResource = nullptr;
    result = sharedTexture->QueryInterface(IID_IDXGIResource1, reinterpret_cast<void**>(&sharedResource));
    if (FAILED(result)) {
        release(sharedTexture);
        release(device1);
        release(context);
        release(device);
        return fail("QueryInterface(IDXGIResource1)", result);
    }

    HANDLE sharedHandle = nullptr;
    result = sharedResource->CreateSharedHandle(
        nullptr,
        DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
        nullptr,
        &sharedHandle);
    if (FAILED(result)) {
        release(sharedResource);
        release(sharedTexture);
        release(device1);
        release(context);
        release(device);
        return fail("IDXGIResource1::CreateSharedHandle", result);
    }

    ID3D11Texture2D* reopenedTexture = nullptr;
    result = device1->OpenSharedResource1(
        sharedHandle,
        IID_ID3D11Texture2D,
        reinterpret_cast<void**>(&reopenedTexture));
    if (FAILED(result)) {
        CloseHandle(sharedHandle);
        release(sharedResource);
        release(sharedTexture);
        release(device1);
        release(context);
        release(device);
        return fail("ID3D11Device1::OpenSharedResource1", result);
    }

    D3D11_TEXTURE2D_DESC stagingDescription = sharedDescription;
    stagingDescription.Usage = D3D11_USAGE_STAGING;
    stagingDescription.BindFlags = 0;
    stagingDescription.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    stagingDescription.MiscFlags = 0;

    ID3D11Texture2D* stagingTexture = nullptr;
    result = device->CreateTexture2D(&stagingDescription, nullptr, &stagingTexture);
    if (SUCCEEDED(result)) {
        context->CopyResource(stagingTexture, reopenedTexture);
        D3D11_MAPPED_SUBRESOURCE mapped{};
        result = context->Map(stagingTexture, 0, D3D11_MAP_READ, 0, &mapped);
        if (SUCCEEDED(result)) {
            for (uint32_t row = 0; row < kHeight; ++row) {
                const auto* actual = static_cast<const uint8_t*>(mapped.pData) + row * mapped.RowPitch;
                const auto* expected = reinterpret_cast<const uint8_t*>(kPixels) +
                                       row * kWidth * sizeof(uint32_t);
                if (std::memcmp(actual, expected, kWidth * sizeof(uint32_t)) != 0) {
                    result = E_FAIL;
                    break;
                }
            }
            context->Unmap(stagingTexture, 0);
        }
    }

    release(stagingTexture);
    release(reopenedTexture);
    CloseHandle(sharedHandle);
    release(sharedResource);
    release(sharedTexture);
    release(device1);
    release(context);
    release(device);

    if (FAILED(result)) {
        return fail("shared-texture GPU copy/readback verification", result);
    }

    std::printf(
        "PASS: D3D11 NT-handle texture reopened and verified at feature level 0x%04x\n",
        static_cast<unsigned int>(selectedFeatureLevel));
    return 0;
}
