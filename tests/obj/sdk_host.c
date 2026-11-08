// compiler-guide.md "Building an object for a C host": a C host compiled with only
// the flags `-print-toolchain` reports. `windows.h` needs the Windows SDK's `um`
// and `shared` headers, and an `_mm_*` intrinsic links only when clang's
// `immintrin.h` is found ahead of MSVC's. Exits 0 when both hold.
#include <windows.h>
#include <immintrin.h>

int main(void) {
    __m128 doubled = _mm_add_ps(_mm_set1_ps(1.5f), _mm_set1_ps(1.5f));
    float lanes[4];
    _mm_storeu_ps(lanes, doubled);
    if (lanes[0] != 3.0f || lanes[3] != 3.0f) {
        return 1;
    }
    return GetCurrentProcessId() != 0 ? 0 : 2;
}
