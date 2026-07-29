#include <windows.h>

#include <openxr/openxr.h>
#include <openxr/openxr_loader_negotiation.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

namespace {

int failures = 0;

void check(bool condition, const char* message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        ++failures;
    }
}

XrNegotiateLoaderInfo validLoaderInfo() {
    XrNegotiateLoaderInfo info{};
    info.structType = XR_LOADER_INTERFACE_STRUCT_LOADER_INFO;
    info.structVersion = XR_LOADER_INFO_STRUCT_VERSION;
    info.structSize = sizeof(info);
    info.minInterfaceVersion = 1;
    info.maxInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION;
    info.minApiVersion = XR_MAKE_VERSION(1, 0, 0);
    info.maxApiVersion = XR_MAKE_VERSION(1, 0x3ff, 0xfff);
    return info;
}

XrNegotiateRuntimeRequest validRuntimeRequest() {
    XrNegotiateRuntimeRequest request{};
    request.structType = XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST;
    request.structVersion = XR_RUNTIME_INFO_STRUCT_VERSION;
    request.structSize = sizeof(request);
    return request;
}

}  // namespace

int main(int argc, char** argv) {
    const char* dllPath = argc > 1 ? argv[1] : "basalt_openxr.dll";
    HMODULE runtime = LoadLibraryA(dllPath);
    check(runtime != nullptr, "LoadLibraryA loads basalt_openxr.dll");
    if (runtime == nullptr) {
        std::fprintf(stderr, "Windows error: %lu\n", GetLastError());
        return 1;
    }

    FARPROC negotiateAddress = GetProcAddress(runtime, "xrNegotiateLoaderRuntimeInterface");
    PFN_xrNegotiateLoaderRuntimeInterface negotiate = nullptr;
    static_assert(sizeof(negotiate) == sizeof(negotiateAddress));
    std::memcpy(&negotiate, &negotiateAddress, sizeof(negotiate));
    check(negotiate != nullptr, "runtime exports unmangled negotiation entry point");
    if (negotiate == nullptr) {
        FreeLibrary(runtime);
        return 1;
    }

    auto loaderInfo = validLoaderInfo();
    auto runtimeRequest = validRuntimeRequest();
    check(negotiate(&loaderInfo, &runtimeRequest) == XR_SUCCESS, "valid negotiation succeeds");
    check(runtimeRequest.runtimeInterfaceVersion == 1, "runtime selects interface version 1");
    check(XR_VERSION_MAJOR(runtimeRequest.runtimeApiVersion) == 1 &&
              XR_VERSION_MINOR(runtimeRequest.runtimeApiVersion) == 0,
          "runtime selects OpenXR 1.0");
    check(runtimeRequest.getInstanceProcAddr != nullptr, "runtime supplies xrGetInstanceProcAddr");

    check(negotiate(nullptr, &runtimeRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "null loader info is rejected");
    check(negotiate(&loaderInfo, nullptr) == XR_ERROR_INITIALIZATION_FAILED,
          "null runtime request is rejected");

    auto badLoaderInfo = validLoaderInfo();
    badLoaderInfo.structType = XR_LOADER_INTERFACE_STRUCT_UNINTIALIZED;
    auto scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad loader struct type is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.structVersion += 1;
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad loader struct version is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.structSize -= 1;
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad loader struct size is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.minInterfaceVersion = 2;
    badLoaderInfo.maxInterfaceVersion = 2;
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "incompatible loader interface is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.minInterfaceVersion = 1;
    badLoaderInfo.maxInterfaceVersion = 0;
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "reversed interface range is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.minApiVersion = XR_MAKE_VERSION(2, 0, 0);
    badLoaderInfo.maxApiVersion = XR_MAKE_VERSION(2, 0, 0);
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "incompatible API range is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.minApiVersion = XR_MAKE_VERSION(1, 1, 0);
    badLoaderInfo.maxApiVersion = XR_MAKE_VERSION(1, 0, 0);
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "reversed API range is rejected");

    badLoaderInfo = validLoaderInfo();
    badLoaderInfo.minApiVersion = XR_MAKE_VERSION(1, 0, 999);
    badLoaderInfo.maxApiVersion = XR_MAKE_VERSION(1, 0, 999);
    scratchRequest = validRuntimeRequest();
    check(negotiate(&badLoaderInfo, &scratchRequest) == XR_SUCCESS,
          "API negotiation ignores patch-only differences");

    auto badRuntimeRequest = validRuntimeRequest();
    badRuntimeRequest.structSize -= 1;
    check(negotiate(&loaderInfo, &badRuntimeRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad runtime request struct is rejected");

    badRuntimeRequest = validRuntimeRequest();
    badRuntimeRequest.structType = XR_LOADER_INTERFACE_STRUCT_UNINTIALIZED;
    check(negotiate(&loaderInfo, &badRuntimeRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad runtime request type is rejected");

    badRuntimeRequest = validRuntimeRequest();
    badRuntimeRequest.structVersion += 1;
    check(negotiate(&loaderInfo, &badRuntimeRequest) == XR_ERROR_INITIALIZATION_FAILED,
          "bad runtime request version is rejected");

    PFN_xrVoidFunction cleared = reinterpret_cast<PFN_xrVoidFunction>(UINTPTR_MAX);
    check(runtimeRequest.getInstanceProcAddr(XR_NULL_HANDLE, nullptr, &cleared) ==
              XR_ERROR_VALIDATION_FAILURE && cleared == nullptr,
          "GIPA rejects a null name and clears output");
    check(runtimeRequest.getInstanceProcAddr(XR_NULL_HANDLE, "xrCreateInstance", nullptr) ==
              XR_ERROR_VALIDATION_FAILURE,
          "GIPA rejects a null output pointer");

    PFN_xrVoidFunction unknown = reinterpret_cast<PFN_xrVoidFunction>(UINTPTR_MAX);
    check(runtimeRequest.getInstanceProcAddr(
              XR_NULL_HANDLE, "xrDefinitelyNotBasalt", &unknown) == XR_ERROR_HANDLE_INVALID,
          "non-global null-instance lookup is rejected");
    check(unknown == nullptr, "unknown function pointer is cleared");

    PFN_xrVoidFunction instanceOnly = reinterpret_cast<PFN_xrVoidFunction>(UINTPTR_MAX);
    check(runtimeRequest.getInstanceProcAddr(
              XR_NULL_HANDLE, "xrDestroyInstance", &instanceOnly) == XR_ERROR_HANDLE_INVALID &&
              instanceOnly == nullptr,
          "instance command requires a valid instance");

    PFN_xrVoidFunction enumerateVoid = nullptr;
    check(runtimeRequest.getInstanceProcAddr(
              XR_NULL_HANDLE, "xrEnumerateInstanceExtensionProperties", &enumerateVoid) == XR_SUCCESS &&
              enumerateVoid != nullptr,
          "GIPA exposes extension enumeration");
    auto enumerate = reinterpret_cast<PFN_xrEnumerateInstanceExtensionProperties>(enumerateVoid);
    uint32_t extensionCount = UINT32_MAX;
    check(enumerate(nullptr, 0, &extensionCount, nullptr) == XR_SUCCESS && extensionCount == 0,
          "runtime advertises zero extensions");
    check(enumerate("missing-layer", 0, &extensionCount, nullptr) == XR_ERROR_API_LAYER_NOT_PRESENT,
          "extension enumeration rejects an unknown API layer");
    check(enumerate(nullptr, 1, &extensionCount, nullptr) == XR_ERROR_VALIDATION_FAILURE,
          "extension enumeration validates its output buffer");

    PFN_xrVoidFunction layersVoid = nullptr;
    check(runtimeRequest.getInstanceProcAddr(
              XR_NULL_HANDLE, "xrEnumerateApiLayerProperties", &layersVoid) == XR_SUCCESS &&
              layersVoid != nullptr,
          "GIPA exposes API-layer enumeration");
    auto enumerateLayers = reinterpret_cast<PFN_xrEnumerateApiLayerProperties>(layersVoid);
    uint32_t layerCount = UINT32_MAX;
    check(enumerateLayers(0, &layerCount, nullptr) == XR_SUCCESS && layerCount == 0,
          "runtime advertises zero API layers");

    PFN_xrVoidFunction createVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(XR_NULL_HANDLE, "xrCreateInstance", &createVoid);
    auto create = reinterpret_cast<PFN_xrCreateInstance>(createVoid);
    XrInstanceCreateInfo createInfo{};
    createInfo.type = XR_TYPE_INSTANCE_CREATE_INFO;
    createInfo.applicationInfo.apiVersion = XR_API_VERSION_1_0;
    std::strncpy(createInfo.applicationInfo.applicationName, "Basalt direct smoke",
                 XR_MAX_APPLICATION_NAME_SIZE - 1);
    XrInstance instance = XR_NULL_HANDLE;
    check(create(&createInfo, &instance) == XR_SUCCESS && instance != XR_NULL_HANDLE,
          "direct xrCreateInstance succeeds");

    XrInstance secondInstance = XR_NULL_HANDLE;
    check(create(&createInfo, &secondInstance) == XR_ERROR_LIMIT_REACHED &&
              secondInstance == XR_NULL_HANDLE,
          "runtime bounds simultaneous live instances");

    PFN_xrVoidFunction unknownWithInstance = reinterpret_cast<PFN_xrVoidFunction>(UINTPTR_MAX);
    check(runtimeRequest.getInstanceProcAddr(
              instance, "xrDefinitelyNotBasalt", &unknownWithInstance) == XR_ERROR_FUNCTION_UNSUPPORTED &&
              unknownWithInstance == nullptr,
          "unknown function with a valid instance is unsupported");

    PFN_xrVoidFunction getSystemVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrGetSystem", &getSystemVoid);
    auto getSystem = reinterpret_cast<PFN_xrGetSystem>(getSystemVoid);
    XrSystemGetInfo systemInfo{};
    systemInfo.type = XR_TYPE_SYSTEM_GET_INFO;
    systemInfo.formFactor = XR_FORM_FACTOR_HANDHELD_DISPLAY;
    XrSystemId systemId = 99;
    check(getSystem(instance, &systemInfo, &systemId) == XR_ERROR_FORM_FACTOR_UNSUPPORTED &&
              systemId == XR_NULL_SYSTEM_ID,
          "system discovery rejects unsupported form factors and clears output");
    systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    check(getSystem(instance, &systemInfo, &systemId) == XR_SUCCESS && systemId != XR_NULL_SYSTEM_ID,
          "direct HMD system discovery succeeds");

    PFN_xrVoidFunction systemPropertiesVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrGetSystemProperties", &systemPropertiesVoid);
    auto getSystemProperties = reinterpret_cast<PFN_xrGetSystemProperties>(systemPropertiesVoid);
    XrSystemProperties badSystemProperties{};
    badSystemProperties.type = XR_TYPE_UNKNOWN;
    check(getSystemProperties(instance, systemId, &badSystemProperties) == XR_ERROR_VALIDATION_FAILURE,
          "system properties validate the output structure type");
    badSystemProperties.type = XR_TYPE_SYSTEM_PROPERTIES;
    check(getSystemProperties(instance, systemId + 1, &badSystemProperties) == XR_ERROR_SYSTEM_INVALID,
          "system properties reject an unknown system ID");

    PFN_xrVoidFunction viewConfigurationsVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrEnumerateViewConfigurations", &viewConfigurationsVoid);
    auto enumerateViewConfigurations =
        reinterpret_cast<PFN_xrEnumerateViewConfigurations>(viewConfigurationsVoid);
    uint32_t viewConfigurationCount = 0;
    check(enumerateViewConfigurations(instance, systemId + 1, 0,
                                      &viewConfigurationCount, nullptr) == XR_ERROR_SYSTEM_INVALID,
          "view configuration enumeration rejects an unknown system ID");

    PFN_xrVoidFunction viewsVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrEnumerateViewConfigurationViews", &viewsVoid);
    auto enumerateViews = reinterpret_cast<PFN_xrEnumerateViewConfigurationViews>(viewsVoid);
    uint32_t viewCount = 0;
    check(enumerateViews(instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_MONO,
                         0, &viewCount, nullptr) == XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED,
          "view enumeration rejects unsupported view types");
    XrViewConfigurationView shortViews[1]{};
    shortViews[0].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    check(enumerateViews(instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                         1, &viewCount, shortViews) == XR_ERROR_SIZE_INSUFFICIENT && viewCount == 2,
          "stereo view enumeration reports an undersized output array");
    XrViewConfigurationView directViews[2]{};
    directViews[0].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    directViews[1].type = XR_TYPE_VIEW_CONFIGURATION_VIEW;
    directViews[0].next = reinterpret_cast<void*>(static_cast<uintptr_t>(1));
    directViews[1].next = reinterpret_cast<void*>(static_cast<uintptr_t>(2));
    check(enumerateViews(instance, systemId, XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                         2, &viewCount, directViews) == XR_SUCCESS && viewCount == 2 &&
              directViews[0].next == reinterpret_cast<void*>(static_cast<uintptr_t>(1)) &&
              directViews[1].next == reinterpret_cast<void*>(static_cast<uintptr_t>(2)),
          "stereo view enumeration preserves caller-owned header fields");

    PFN_xrVoidFunction propertiesVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrGetInstanceProperties", &propertiesVoid);
    auto getProperties = reinterpret_cast<PFN_xrGetInstanceProperties>(propertiesVoid);
    XrInstanceProperties properties{};
    properties.type = XR_TYPE_INSTANCE_PROPERTIES;
    properties.next = reinterpret_cast<void*>(static_cast<uintptr_t>(1));
    check(getProperties(instance, &properties) == XR_SUCCESS, "direct xrGetInstanceProperties succeeds");
    check(std::strncmp(properties.runtimeName, "BasaltVR", 8) == 0,
          "runtime properties identify BasaltVR");
    check(properties.type == XR_TYPE_INSTANCE_PROPERTIES &&
              properties.next == reinterpret_cast<void*>(static_cast<uintptr_t>(1)),
          "runtime properties preserve caller-owned header fields");

    PFN_xrVoidFunction destroyVoid = nullptr;
    runtimeRequest.getInstanceProcAddr(instance, "xrDestroyInstance", &destroyVoid);
    auto destroy = reinterpret_cast<PFN_xrDestroyInstance>(destroyVoid);
    check(destroy(instance) == XR_SUCCESS, "direct xrDestroyInstance succeeds");
    check(destroy(instance) == XR_ERROR_HANDLE_INVALID, "double destroy rejects a stale handle");
    check(getProperties(instance, &properties) == XR_ERROR_HANDLE_INVALID,
          "properties reject a destroyed handle");
    check(destroy(reinterpret_cast<XrInstance>(static_cast<uintptr_t>(0x1234))) == XR_ERROR_HANDLE_INVALID,
          "destroy rejects a forged handle without dereferencing it");

    XrInstance replacement = XR_NULL_HANDLE;
    check(create(&createInfo, &replacement) == XR_SUCCESS && replacement != XR_NULL_HANDLE,
          "instance can be recreated after destroy");
    check(destroy(instance) == XR_ERROR_HANDLE_INVALID,
          "an old handle cannot target a newly created instance");
    systemId = XR_NULL_SYSTEM_ID;
    check(getSystem(instance, &systemInfo, &systemId) == XR_ERROR_HANDLE_INVALID,
          "system discovery rejects a stale instance handle");
    check(destroy(replacement) == XR_SUCCESS, "replacement instance is destroyed");

    for (uint32_t cycle = 0; cycle < 128; ++cycle) {
        XrInstance cycledInstance = XR_NULL_HANDLE;
        if (create(&createInfo, &cycledInstance) != XR_SUCCESS ||
            destroy(cycledInstance) != XR_SUCCESS) {
            check(false, "instance handle generation survives repeated create/destroy cycles");
            break;
        }
    }

    FreeLibrary(runtime);
    if (failures != 0) {
        std::fprintf(stderr, "%d negotiation smoke check(s) failed\n", failures);
        return 1;
    }
    std::puts("PASS: BasaltVR runtime negotiation and direct lifecycle");
    return 0;
}
