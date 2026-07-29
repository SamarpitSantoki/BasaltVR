#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
runtime_dir=${script_dir:h}
build_dir=${BUILD_DIR:-${runtime_dir}/build}
toolchain=${runtime_dir}/cmake/toolchains/mingw-x86_64.cmake

cmake_bin=${CMAKE:-$(command -v cmake || true)}
objdump_bin=${OBJDUMP:-$(command -v x86_64-w64-mingw32-objdump || true)}
wine_bin=${WINE:-${HOME}/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64}
# Intentionally ignore ambient WINEPREFIX: this script writes the active-runtime HKLM value.
wine_prefix=${BASALT_WINEPREFIX:-${build_dir}/wineprefix}
unset XR_RUNTIME_JSON

if [[ -z ${cmake_bin} || -z ${objdump_bin} || ! -x ${wine_bin} ]]; then
    print -u2 "Missing CMake, MinGW objdump, or WhiskyWine. See runtime/README.md."
    exit 1
fi

configure_args=(
    -S "${runtime_dir}"
    -B "${build_dir}"
    -DCMAKE_BUILD_TYPE=Release
)
if [[ ! -f ${build_dir}/CMakeCache.txt ]]; then
    configure_args+=("-DCMAKE_TOOLCHAIN_FILE=${toolchain}")
fi
"${cmake_bin}" "${configure_args[@]}"
"${cmake_bin}" --build "${build_dir}" --parallel

bin_dir=${build_dir}/bin
dll=${bin_dir}/basalt_openxr.dll
manifest=${bin_dir}/basalt_openxr.json

if [[ $(file "${dll}") != *"PE32+ executable (DLL)"*"x86-64"* ]]; then
    print -u2 "FAIL: ${dll} is not a PE32+ x86-64 DLL"
    exit 1
fi

export_names=$("${objdump_bin}" -p "${dll}" | awk '
    /\[Ordinal\/Name Pointer\] Table/ { in_exports = 1; next }
    /The Function Table/ { in_exports = 0 }
    in_exports && /\+base/ { print $NF }
')
if [[ ${export_names} != "xrNegotiateLoaderRuntimeInterface" ]]; then
    print -u2 "FAIL: unexpected DLL exports: ${export_names}"
    exit 1
fi

pushd "${bin_dir}" >/dev/null
WINEPREFIX=${wine_prefix} WINEDEBUG=-all "${wine_bin}" \
    ./negotiation_smoke.exe ./basalt_openxr.dll

# WhiskyWine reports an elevated token, so the Khronos loader correctly ignores
# XR_RUNTIME_JSON. Register the runtime in an isolated generated prefix instead.
manifest_windows="Z:${manifest//\//\\}"
WINEPREFIX=${wine_prefix} WINEDEBUG=-all "${wine_bin}" reg.exe add \
    'HKLM\Software\Khronos\OpenXR\1' \
    /v ActiveRuntime /t REG_SZ /d "${manifest_windows}" /f
WINEPREFIX=${wine_prefix} WINEDEBUG=-all "${wine_bin}" ./loader_smoke.exe
popd >/dev/null

print "PASS: PE inspection, direct ABI smoke, and official-loader WhiskyWine smoke"
