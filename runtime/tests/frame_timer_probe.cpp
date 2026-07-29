#include <windows.h>

#include <algorithm>
#include <cstdio>

#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif

namespace {

constexpr int kIntervals = 144;

double elapsedSeconds(const LARGE_INTEGER& start, const LARGE_INTEGER& end,
                      const LARGE_INTEGER& frequency) {
    return static_cast<double>(end.QuadPart - start.QuadPart) /
           static_cast<double>(frequency.QuadPart);
}

}  // namespace

int main() {
    LARGE_INTEGER frequency{};
    LARGE_INTEGER started{};
    LARGE_INTEGER ended{};
    if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0) {
        std::fprintf(stderr, "FAIL: QueryPerformanceFrequency\n");
        return 1;
    }

    QueryPerformanceCounter(&started);
    for (int index = 0; index < kIntervals; ++index) {
        Sleep(14);
    }
    QueryPerformanceCounter(&ended);
    const double sleepSeconds = elapsedSeconds(started, ended, frequency);

    HANDLE timer = CreateWaitableTimerExW(
        nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    if (timer == nullptr) {
        timer = CreateWaitableTimerW(nullptr, FALSE, nullptr);
    }
    if (timer == nullptr) {
        std::fprintf(stderr, "FAIL: CreateWaitableTimer\n");
        return 1;
    }

    QueryPerformanceCounter(&started);
    for (int index = 0; index < kIntervals; ++index) {
        LARGE_INTEGER due{};
        LARGE_INTEGER now{};
        QueryPerformanceCounter(&now);
        const LONGLONG target = started.QuadPart +
            ((static_cast<LONGLONG>(index) + 1) * frequency.QuadPart) / 72;
        const LONGLONG remainingTicks = target - now.QuadPart;
        if (remainingTicks <= 0) {
            continue;
        }
        const LONGLONG remaining100ns =
            (remainingTicks * 10'000'000) / frequency.QuadPart;
        due.QuadPart = -std::max<LONGLONG>(1, remaining100ns);
        if (!SetWaitableTimer(timer, &due, 0, nullptr, nullptr, FALSE) ||
            WaitForSingleObject(timer, 1000) != WAIT_OBJECT_0) {
            CloseHandle(timer);
            std::fprintf(stderr, "FAIL: waitable timer interval\n");
            return 1;
        }
    }
    QueryPerformanceCounter(&ended);
    CloseHandle(timer);
    const double timerSeconds = elapsedSeconds(started, ended, frequency);

    const double sleepHz = static_cast<double>(kIntervals) / sleepSeconds;
    const double timerHz = static_cast<double>(kIntervals) / timerSeconds;
    std::printf("Sleep(14): %.2f Hz; absolute waitable 72 Hz: %.2f Hz\n", sleepHz, timerHz);
    if (timerHz < 68.0 || timerHz > 76.0) {
        std::fprintf(stderr, "FAIL: waitable timer did not hold the 72 Hz cadence\n");
        return 1;
    }
    std::printf("PASS: waitable timer supports the 72 Hz OpenXR cadence\n");
    return 0;
}
