#include <windows.h>

#include <d3d11.h>
#include <dxgi1_2.h>

#include <cstdio>

namespace {

LRESULT CALLBACK windowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    return DefWindowProcW(window, message, wparam, lparam);
}

template <typename Interface>
void release(Interface*& object) {
    if (object != nullptr) {
        object->Release();
        object = nullptr;
    }
}

int fail(const char* operation, HRESULT result = E_FAIL) {
    std::fprintf(stderr, "FAIL: %s (HRESULT 0x%08lx)\n", operation,
                 static_cast<unsigned long>(result));
    return 1;
}

}  // namespace

int WINAPI WinMain(HINSTANCE instance, HINSTANCE, LPSTR, int) {
    constexpr wchar_t kClassName[] = L"BasaltDXMTWindowProbe";
    WNDCLASSW windowClass{};
    windowClass.lpfnWndProc = windowProc;
    windowClass.hInstance = instance;
    windowClass.lpszClassName = kClassName;
    if (!RegisterClassW(&windowClass)) {
        return fail("RegisterClassW");
    }

    HWND window = CreateWindowExW(
        0, kClassName, L"Basalt DXMT window probe", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 320, 240, nullptr, nullptr, instance, nullptr);
    if (window == nullptr) {
        return fail("CreateWindowExW");
    }
    ShowWindow(window, SW_SHOW);

    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    D3D_FEATURE_LEVEL featureLevel{};
    HRESULT result = D3D11CreateDevice(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        nullptr, 0, D3D11_SDK_VERSION, &device, &featureLevel, &context);
    if (FAILED(result)) {
        DestroyWindow(window);
        return fail("D3D11CreateDevice", result);
    }

    IDXGIDevice* dxgiDevice = nullptr;
    IDXGIAdapter* adapter = nullptr;
    IDXGIFactory2* factory = nullptr;
    IDXGISwapChain1* swapchain = nullptr;
    result = device->QueryInterface(IID_IDXGIDevice, reinterpret_cast<void**>(&dxgiDevice));
    if (SUCCEEDED(result)) {
        result = dxgiDevice->GetAdapter(&adapter);
    }
    if (SUCCEEDED(result)) {
        result = adapter->GetParent(IID_IDXGIFactory2, reinterpret_cast<void**>(&factory));
    }
    if (SUCCEEDED(result)) {
        DXGI_SWAP_CHAIN_DESC1 description{};
        description.Width = 320;
        description.Height = 240;
        description.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        description.SampleDesc.Count = 1;
        description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        description.BufferCount = 2;
        description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        result = factory->CreateSwapChainForHwnd(
            device, window, &description, nullptr, nullptr, &swapchain);
    }
    if (SUCCEEDED(result)) {
        result = swapchain->Present(0, 0);
    }

    release(swapchain);
    release(factory);
    release(adapter);
    release(dxgiDevice);
    release(context);
    release(device);
    DestroyWindow(window);

    if (FAILED(result)) {
        return fail("CreateSwapChainForHwnd/Present", result);
    }
    std::puts("PASS: DXMT created and presented a Win32 Metal-backed swapchain");
    return 0;
}
