#include "runtime.hpp"

#include <openxr/openxr_loader_negotiation.h>

extern "C" XRAPI_ATTR XrResult XRAPI_CALL xrNegotiateLoaderRuntimeInterface(
    const XrNegotiateLoaderInfo* loaderInfo,
    XrNegotiateRuntimeRequest* runtimeRequest) {
    if (loaderInfo == nullptr || runtimeRequest == nullptr) {
        return XR_ERROR_INITIALIZATION_FAILED;
    }
    if (loaderInfo->structType != XR_LOADER_INTERFACE_STRUCT_LOADER_INFO ||
        loaderInfo->structVersion != XR_LOADER_INFO_STRUCT_VERSION ||
        loaderInfo->structSize != sizeof(XrNegotiateLoaderInfo)) {
        return XR_ERROR_INITIALIZATION_FAILED;
    }
    if (runtimeRequest->structType != XR_LOADER_INTERFACE_STRUCT_RUNTIME_REQUEST ||
        runtimeRequest->structVersion != XR_RUNTIME_INFO_STRUCT_VERSION ||
        runtimeRequest->structSize != sizeof(XrNegotiateRuntimeRequest)) {
        return XR_ERROR_INITIALIZATION_FAILED;
    }
    if (loaderInfo->minInterfaceVersion > loaderInfo->maxInterfaceVersion ||
        loaderInfo->minInterfaceVersion > XR_CURRENT_LOADER_RUNTIME_VERSION ||
        loaderInfo->maxInterfaceVersion < XR_CURRENT_LOADER_RUNTIME_VERSION) {
        return XR_ERROR_INITIALIZATION_FAILED;
    }
    const XrVersion minimumApi = XR_MAKE_VERSION(
        XR_VERSION_MAJOR(loaderInfo->minApiVersion),
        XR_VERSION_MINOR(loaderInfo->minApiVersion),
        0);
    const XrVersion maximumApi = XR_MAKE_VERSION(
        XR_VERSION_MAJOR(loaderInfo->maxApiVersion),
        XR_VERSION_MINOR(loaderInfo->maxApiVersion),
        0);
    if (minimumApi > maximumApi ||
        minimumApi > basalt::kRuntimeApiVersion ||
        maximumApi < basalt::kRuntimeApiVersion) {
        return XR_ERROR_INITIALIZATION_FAILED;
    }

    runtimeRequest->runtimeInterfaceVersion = XR_CURRENT_LOADER_RUNTIME_VERSION;
    runtimeRequest->runtimeApiVersion = basalt::kRuntimeApiVersion;
    runtimeRequest->getInstanceProcAddr = basalt::getInstanceProcAddr;
    return XR_SUCCESS;
}
