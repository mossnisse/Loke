// The heap allocator, except that it refuses any block of 64 KiB or more, for
// `process_output_fault.loke`.
#include "loke_rt.h"

static const loke_rt_allocator_v1 *heap;

static void *allocate(void *state, uint64_t size, uint64_t align) {
    (void)state;
    return size >= 65536 ? 0 : heap->ops->alloc(heap->state, size, align);
}

static void *resize(void *state, void *ptr, uint64_t old, uint64_t size, uint64_t align) {
    (void)state;
    return size >= 65536 ? 0 : heap->ops->resize(heap->state, ptr, old, size, align);
}

static void release(void *state, void *ptr, uint64_t size, uint64_t align) {
    (void)state;
    heap->ops->free(heap->state, ptr, size, align);
}

static int32_t reset(void *state) {
    (void)state;
    return 0;
}

static const loke_rt_allocator_ops_v1 ops = {allocate, resize, release, reset};
static const loke_rt_allocator_v1 allocator = {1, 40, 0, 0, &ops, 0, 0};

void install_fault(void) {
    heap = loke_rt_v1_selected_allocator();
    loke_rt_v1_publish_allocator(&allocator);
}
