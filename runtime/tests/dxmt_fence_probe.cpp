#include <windows.h>

#include <d3d11_4.h>
#include <dxgi1_2.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

// Probes the Phase-1 frame-completion mechanism from docs/DXMT-INTEROP.md:
// a non-shared ID3D11Fence signaled on the immediate context after queued GPU
// work, waited on the CPU through SetEventOnCompletion. The frame-done
// contract is that the event firing implies all GPU work queued before the
// Signal is complete and its results are visible. CreateFence(SHARED) is
// probed separately and reported without failing: Phase 1 keeps the wait
// in-process, so a missing D3DKMT shared-fence escape must not block it.

namespace {

constexpr DWORD kFenceWaitMilliseconds = 10000;

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
        "The Phase-1 frame-completion design in docs/DXMT-INTEROP.md requires this.\n",
        operation,
        static_cast<unsigned long>(result));
    return 1;
}

int failWait(const char* operation, DWORD waitStatus) {
    std::fprintf(
        stderr,
        "FAIL: %s wait returned %lu (timeout %lu ms)\n"
        "The fence event never fired; FrameReady signaling cannot work this way.\n",
        operation,
        static_cast<unsigned long>(waitStatus),
        static_cast<unsigned long>(kFenceWaitMilliseconds));
    return 1;
}

}  // namespace

int main() {
    constexpr uint32_t kWidth = 4;
    constexpr uint32_t kHeight = 4;
    constexpr uint32_t kPixels[kWidth * kHeight] = {
        0xffa1a2a3, 0xffa4a5a6, 0xffa7a8a9, 0xffaaabac,
        0xffb1b2b3, 0xffb4b5b6, 0xffb7b8b9, 0xffbabbbc,
        0xffc1c2c3, 0xffc4c5c6, 0xffc7c8c9, 0xffcacbcc,
        0xffd1d2d3, 0xffd4d5d6, 0xffd7d8d9, 0xffdadbdc,
    };

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

    ID3D11Device5* device5 = nullptr;
    result = device->QueryInterface(IID_ID3D11Device5, reinterpret_cast<void**>(&device5));
    if (FAILED(result)) {
        release(context);
        release(device);
        return fail("QueryInterface(ID3D11Device5)", result);
    }

    ID3D11DeviceContext4* context4 = nullptr;
    result = context->QueryInterface(IID_ID3D11DeviceContext4, reinterpret_cast<void**>(&context4));
    if (FAILED(result)) {
        release(device5);
        release(context);
        release(device);
        return fail("QueryInterface(ID3D11DeviceContext4)", result);
    }

    ID3D11Fence* fence = nullptr;
    result = device5->CreateFence(0, D3D11_FENCE_FLAG_NONE, IID_ID3D11Fence,
                                  reinterpret_cast<void**>(&fence));
    if (FAILED(result)) {
        release(context4);
        release(device5);
        release(context);
        release(device);
        return fail("ID3D11Device5::CreateFence(NONE)", result);
    }

    int exitCode = 0;
    ID3D11Texture2D* sourceTexture = nullptr;
    ID3D11Texture2D* stagingTexture = nullptr;
    HANDLE frameEvent = nullptr;
    HANDLE lateEvent = nullptr;
    HANDLE secondFrameEvent = nullptr;

    do {
        if (fence->GetCompletedValue() != 0) {
            exitCode = fail("ID3D11Fence::GetCompletedValue initial value", E_FAIL);
            break;
        }

        D3D11_TEXTURE2D_DESC sourceDescription{};
        sourceDescription.Width = kWidth;
        sourceDescription.Height = kHeight;
        sourceDescription.MipLevels = 1;
        sourceDescription.ArraySize = 1;
        sourceDescription.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        sourceDescription.SampleDesc.Count = 1;
        sourceDescription.Usage = D3D11_USAGE_DEFAULT;
        sourceDescription.BindFlags = D3D11_BIND_SHADER_RESOURCE;

        D3D11_SUBRESOURCE_DATA initialData{};
        initialData.pSysMem = kPixels;
        initialData.SysMemPitch = kWidth * sizeof(uint32_t);

        result = device->CreateTexture2D(&sourceDescription, &initialData, &sourceTexture);
        if (FAILED(result)) {
            exitCode = fail("CreateTexture2D(source)", result);
            break;
        }

        D3D11_TEXTURE2D_DESC stagingDescription = sourceDescription;
        stagingDescription.Usage = D3D11_USAGE_STAGING;
        stagingDescription.BindFlags = 0;
        stagingDescription.CPUAccessFlags = D3D11_CPU_ACCESS_READ;

        result = device->CreateTexture2D(&stagingDescription, nullptr, &stagingTexture);
        if (FAILED(result)) {
            exitCode = fail("CreateTexture2D(staging)", result);
            break;
        }

        frameEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (frameEvent == nullptr) {
            exitCode = fail("CreateEventW", HRESULT_FROM_WIN32(GetLastError()));
            break;
        }

        result = fence->SetEventOnCompletion(1, frameEvent);
        if (FAILED(result)) {
            exitCode = fail("ID3D11Fence::SetEventOnCompletion(1)", result);
            break;
        }

        // Nothing is signaled yet: the event must not fire early or the
        // whole completion contract is meaningless.
        DWORD waitStatus = WaitForSingleObject(frameEvent, 0);
        if (waitStatus != WAIT_TIMEOUT) {
            std::fprintf(stderr,
                         "FAIL: fence event fired before any Signal (wait returned %lu)\n",
                         static_cast<unsigned long>(waitStatus));
            exitCode = 1;
            break;
        }

        context->CopyResource(stagingTexture, sourceTexture);
        result = context4->Signal(fence, 1);
        if (FAILED(result)) {
            exitCode = fail("ID3D11DeviceContext4::Signal(1)", result);
            break;
        }
        context->Flush();

        waitStatus = WaitForSingleObject(frameEvent, kFenceWaitMilliseconds);
        if (waitStatus != WAIT_OBJECT_0) {
            exitCode = failWait("frame fence", waitStatus);
            break;
        }

        if (fence->GetCompletedValue() < 1) {
            exitCode = fail("ID3D11Fence::GetCompletedValue after signaled wait", E_FAIL);
            break;
        }

        // The frame-done contract Phase 1 needs is GPU-queue ordering: the
        // event firing means the copy finished on the GPU. D3D11 CPU map
        // bookkeeping is allowed to lag that (DXMT v0.80 clears DO_NOT_WAIT
        // via its own completion handler slightly after the fence event), so
        // measure the lag instead of failing instantly; wrong pixels or a
        // lag beyond one second still fail.
        D3D11_MAPPED_SUBRESOURCE mapped{};
        const ULONGLONG mapStart = GetTickCount64();
        ULONGLONG mapLagMilliseconds = 0;
        for (;;) {
            result = context->Map(stagingTexture, 0, D3D11_MAP_READ,
                                  D3D11_MAP_FLAG_DO_NOT_WAIT, &mapped);
            if (result != DXGI_ERROR_WAS_STILL_DRAWING) {
                mapLagMilliseconds = GetTickCount64() - mapStart;
                break;
            }
            if (GetTickCount64() - mapStart >= 1000) {
                break;
            }
            Sleep(1);
        }
        if (result == DXGI_ERROR_WAS_STILL_DRAWING) {
            std::fprintf(stderr,
                         "FAIL: Map(DO_NOT_WAIT) did not clear within 1000 ms of the "
                         "fence event; the measured lag under DXMT v0.80 is ~1 ms\n");
            exitCode = 1;
            break;
        }
        if (SUCCEEDED(result) && mapLagMilliseconds > 0) {
            std::printf(
                "INFO: Map(DO_NOT_WAIT) cleared %llu ms after the fence event\n",
                static_cast<unsigned long long>(mapLagMilliseconds));
        }
        if (FAILED(result)) {
            exitCode = fail("Map(staging) after fence completion", result);
            break;
        }
        bool pixelsMatch = true;
        for (uint32_t row = 0; row < kHeight; ++row) {
            const auto* actual = static_cast<const uint8_t*>(mapped.pData) + row * mapped.RowPitch;
            const auto* expected = reinterpret_cast<const uint8_t*>(kPixels) +
                                   row * kWidth * sizeof(uint32_t);
            if (std::memcmp(actual, expected, kWidth * sizeof(uint32_t)) != 0) {
                pixelsMatch = false;
                break;
            }
        }
        context->Unmap(stagingTexture, 0);
        if (!pixelsMatch) {
            exitCode = fail("staging readback verification after fence completion", E_FAIL);
            break;
        }

        // A wait registered after the value already completed must fire
        // immediately; the runtime thread may only start waiting after the
        // GPU has finished a fast frame.
        lateEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (lateEvent == nullptr) {
            exitCode = fail("CreateEventW(late)", HRESULT_FROM_WIN32(GetLastError()));
            break;
        }
        result = fence->SetEventOnCompletion(1, lateEvent);
        if (FAILED(result)) {
            exitCode = fail("ID3D11Fence::SetEventOnCompletion(completed value)", result);
            break;
        }
        waitStatus = WaitForSingleObject(lateEvent, kFenceWaitMilliseconds);
        if (waitStatus != WAIT_OBJECT_0) {
            exitCode = failWait("already-completed fence", waitStatus);
            break;
        }

        // Per-frame reuse: one fence, monotonically increasing values.
        secondFrameEvent = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (secondFrameEvent == nullptr) {
            exitCode = fail("CreateEventW(second frame)", HRESULT_FROM_WIN32(GetLastError()));
            break;
        }
        result = fence->SetEventOnCompletion(2, secondFrameEvent);
        if (FAILED(result)) {
            exitCode = fail("ID3D11Fence::SetEventOnCompletion(2)", result);
            break;
        }
        waitStatus = WaitForSingleObject(secondFrameEvent, 0);
        if (waitStatus != WAIT_TIMEOUT) {
            std::fprintf(stderr,
                         "FAIL: second-frame event fired before Signal(2) (wait returned %lu)\n",
                         static_cast<unsigned long>(waitStatus));
            exitCode = 1;
            break;
        }
        result = context4->Signal(fence, 2);
        if (FAILED(result)) {
            exitCode = fail("ID3D11DeviceContext4::Signal(2)", result);
            break;
        }
        context->Flush();
        waitStatus = WaitForSingleObject(secondFrameEvent, kFenceWaitMilliseconds);
        if (waitStatus != WAIT_OBJECT_0) {
            exitCode = failWait("second frame fence", waitStatus);
            break;
        }
    } while (false);

    if (secondFrameEvent != nullptr) {
        CloseHandle(secondFrameEvent);
    }
    if (lateEvent != nullptr) {
        CloseHandle(lateEvent);
    }
    if (frameEvent != nullptr) {
        CloseHandle(frameEvent);
    }
    release(stagingTexture);
    release(sourceTexture);
    release(fence);

    // Informational only: Phase 2 / cross-process waits would want a shared
    // fence, but Phase 1 must not depend on the Wine D3DKMT escape existing.
    const char* sharedFenceReport = "unavailable";
    if (exitCode == 0) {
        ID3D11Fence* sharedFence = nullptr;
        HRESULT sharedResult = device5->CreateFence(0, D3D11_FENCE_FLAG_SHARED, IID_ID3D11Fence,
                                                    reinterpret_cast<void**>(&sharedFence));
        if (SUCCEEDED(sharedResult)) {
            HANDLE sharedHandle = nullptr;
            sharedResult = sharedFence->CreateSharedHandle(nullptr, GENERIC_ALL, nullptr,
                                                           &sharedHandle);
            if (SUCCEEDED(sharedResult)) {
                sharedFenceReport = "available";
                CloseHandle(sharedHandle);
            } else {
                sharedFenceReport = "created, but CreateSharedHandle failed";
            }
            release(sharedFence);
        }
        if (sharedFenceReport[0] != 'a') {
            std::printf(
                "INFO: shared fence %s (HRESULT 0x%08lx); Phase 1 is unaffected\n",
                sharedFenceReport,
                static_cast<unsigned long>(sharedResult));
        }
    }

    release(context4);
    release(device5);
    release(context);
    release(device);

    if (exitCode != 0) {
        return exitCode;
    }

    std::printf(
        "PASS: D3D11 fence Signal/SetEventOnCompletion frame-done contract verified "
        "(shared fence: %s)\n",
        sharedFenceReport);
    return 0;
}
