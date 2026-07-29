#pragma once

#include_next <d3d11_4.h>

// These two Windows SDK convenience constructors are used by hello_xr but
// are not included in MinGW's otherwise complete D3D11 helper set.
#if defined(__cplusplus) && !defined(BASALT_HELLO_XR_D3D11_HELPERS)
#define BASALT_HELLO_XR_D3D11_HELPERS

struct CD3D11_DEPTH_STENCIL_VIEW_DESC : public D3D11_DEPTH_STENCIL_VIEW_DESC {
    CD3D11_DEPTH_STENCIL_VIEW_DESC(
        D3D11_DSV_DIMENSION dimension,
        DXGI_FORMAT viewFormat,
        UINT mipSlice,
        UINT firstArraySlice,
        UINT arraySize) {
        Format = viewFormat;
        ViewDimension = dimension;
        Flags = 0;
        Texture2DArray.MipSlice = mipSlice;
        Texture2DArray.FirstArraySlice = firstArraySlice;
        Texture2DArray.ArraySize = arraySize;
    }
};

struct CD3D11_VIEWPORT : public D3D11_VIEWPORT {
    CD3D11_VIEWPORT(
        float topLeftX,
        float topLeftY,
        float width,
        float height,
        float minDepth = 0.0f,
        float maxDepth = 1.0f) {
        TopLeftX = topLeftX;
        TopLeftY = topLeftY;
        Width = width;
        Height = height;
        MinDepth = minDepth;
        MaxDepth = maxDepth;
    }
};

#endif
