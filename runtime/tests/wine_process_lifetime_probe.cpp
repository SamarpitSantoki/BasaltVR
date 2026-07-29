#include <cstdlib>
#include <windows.h>

int main(int argc, char **argv) {
    DWORD milliseconds = 2000;
    if (argc > 1) {
        milliseconds = static_cast<DWORD>(std::strtoul(argv[1], nullptr, 10));
    }
    Sleep(milliseconds);
    return 0;
}
