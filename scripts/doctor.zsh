#!/bin/zsh

set -euo pipefail

readonly profile=${1:---core}
case "$profile" in
    --core|--runtime|--dxmt) ;;
    *)
        print -u2 "usage: ${0:t} [--core|--runtime|--dxmt]"
        exit 2
        ;;
esac

failures=()

check_tool() {
    local tool=$1
    local install_hint=$2
    if command -v "$tool" >/dev/null 2>&1; then
        print "  ready  $tool"
    else
        print "  missing $tool ($install_hint)"
        failures+=("$tool")
    fi
}

print "Platform"
if [[ "$(uname -s)" == Darwin ]]; then
    print "  ready  macOS $(sw_vers -productVersion)"
else
    print "  missing macOS (BasaltVR development requires macOS)"
    failures+=("macOS")
fi

if [[ "$(uname -m)" == arm64 ]]; then
    print "  ready  Apple Silicon"
else
    print "  missing Apple Silicon (found $(uname -m))"
    failures+=("Apple Silicon")
fi

if command -v sw_vers >/dev/null 2>&1; then
    readonly macos_major=$(sw_vers -productVersion | cut -d. -f1)
    if (( macos_major >= 14 )); then
        print "  ready  macOS 14+ deployment target"
    else
        print "  missing macOS 14+ deployment target"
        failures+=("macOS 14+")
    fi
fi

print "Core tools"
check_tool git "install Xcode Command Line Tools"
check_tool swift "install Xcode Command Line Tools"
check_tool xcrun "install Xcode Command Line Tools"
check_tool perl "provided by macOS"
check_tool ruby "provided by macOS"

if ! xcode-select -p >/dev/null 2>&1; then
    print "  missing active Xcode developer directory (run xcode-select --install)"
    failures+=("Xcode developer directory")
fi

if [[ "$profile" == --runtime || "$profile" == --dxmt ]]; then
    print "Runtime build tools"
    check_tool cmake "brew install cmake"
    check_tool x86_64-w64-mingw32-g++ "brew install mingw-w64"
    check_tool x86_64-w64-mingw32-objdump "brew install mingw-w64"
fi

if [[ "$profile" == --dxmt ]]; then
    print "DXMT build tools"
    check_tool meson "brew install meson"
    check_tool ninja "brew install ninja"
    check_tool curl "provided by macOS"
    check_tool shasum "provided by macOS"
    check_tool tar "provided by macOS"

    if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
        print "  ready  Xcode Metal toolchain"
    else
        print "  missing Xcode Metal toolchain"
        failures+=("Xcode Metal toolchain")
    fi

    if arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
        print "  ready  Rosetta 2"
    else
        print "  missing Rosetta 2 (softwareupdate --install-rosetta)"
        failures+=("Rosetta 2")
    fi
fi

if (( ${#failures} > 0 )); then
    print -u2
    print -u2 "Environment check failed: ${(j:, :)failures}"
    exit 1
fi

print
print "PASS: ${profile#--} development environment is ready"
