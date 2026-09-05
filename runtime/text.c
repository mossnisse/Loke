/* Runtime text: UTF-8 validation and decoding, and the shared immutable storage
 * behind a `string` value.
 *
 * design.md "string type": a string is immutable, so "sharing their backing
 * storage is never observable as mutable aliasing" — assignment retains a handle
 * rather than copying bytes, and only `.copy()` allocates an independent
 * buffer. The last handle deallocates through the allocator the string was
 * created with, which is why that allocator is part of the buffer's header
 * rather than something the caller has to remember.
 */
#include "loke_rt.h"

#include <string.h>

#define HEADER_ALIGN 8

static loke_rt_string_header_v1 *header_of(uintptr_t owner_flags) {
	if (owner_flags == 0 || owner_flags == LOKE_RT_STRING_STATIC) {
		return 0; /* the empty value, or static literal storage */
	}
	return (loke_rt_string_header_v1 *)owner_flags;
}

/* One block holds the header, the bytes, and the terminator, so a string always
 * has a zero one past its end. `to_c_view` therefore never has to allocate: the
 * terminator design.md lets it "reuse" is always already there. */
static uint8_t *allocate_buffer(
	loke_rt_string_v1 *out, int64_t len, const loke_rt_allocator_v1 *a) {
	uint64_t block = (uint64_t)sizeof(loke_rt_string_header_v1) + (uint64_t)len + 1;
	uint8_t *raw = (uint8_t *)loke_rt_v1_alloc(a, block, HEADER_ALIGN);
	if (raw == 0) {
		return 0;
	}
	loke_rt_string_header_v1 *h = (loke_rt_string_header_v1 *)raw;
	h->handles = 1;
	h->allocator = a;
	h->block_size = block;

	uint8_t *bytes = raw + sizeof(loke_rt_string_header_v1);
	bytes[len] = 0;
	out->data = bytes;
	out->byte_len = len;
	out->owner_flags = (uintptr_t)raw;
	return bytes;
}

static void publish_empty(loke_rt_string_v1 *out) {
	out->data = 0;
	out->byte_len = 0;
	out->owner_flags = 0;
}

void loke_rt_v1_string_retain(uintptr_t owner_flags) {
	loke_rt_string_header_v1 *h = header_of(owner_flags);
	if (h != 0) {
		__atomic_fetch_add(&h->handles, 1, __ATOMIC_RELAXED);
	}
}

void loke_rt_v1_string_release(uintptr_t owner_flags) {
	loke_rt_string_header_v1 *h = header_of(owner_flags);
	if (h == 0) {
		return;
	}
	/* Acquire-release, so the thread that frees the block sees every write the
	 * other handles made before dropping theirs. */
	if (__atomic_fetch_sub(&h->handles, 1, __ATOMIC_ACQ_REL) == 1) {
		loke_rt_v1_free(h->allocator, h, h->block_size, HEADER_ALIGN);
	}
}

/* --------------------------------------------------------------- UTF-8 -- */

/* Rejects overlong encodings, surrogates, and anything above U+10FFFF, so a
 * `string` really does contain valid UTF-8 by construction. */
int64_t loke_rt_v1_rune_at(const uint8_t *data, int64_t len, int64_t offset, int32_t *out_rune) {
	*out_rune = 0xFFFD;
	if (data == 0 || offset < 0 || offset >= len) {
		return 0;
	}
	uint32_t b0 = data[offset];
	if (b0 < 0x80) {
		*out_rune = (int32_t)b0;
		return 1;
	}

	int64_t need;
	uint32_t value;
	uint32_t lowest;
	if ((b0 & 0xE0) == 0xC0) {
		need = 2; value = b0 & 0x1F; lowest = 0x80;
	} else if ((b0 & 0xF0) == 0xE0) {
		need = 3; value = b0 & 0x0F; lowest = 0x800;
	} else if ((b0 & 0xF8) == 0xF0) {
		need = 4; value = b0 & 0x07; lowest = 0x10000;
	} else {
		return 0; /* a continuation byte or an invalid lead */
	}
	if (offset + need > len) {
		return 0;
	}
	for (int64_t i = 1; i < need; i++) {
		uint32_t cont = data[offset + i];
		if ((cont & 0xC0) != 0x80) {
			return 0;
		}
		value = (value << 6) | (cont & 0x3F);
	}
	if (value < lowest || value > 0x10FFFF || (value >= 0xD800 && value <= 0xDFFF)) {
		return 0;
	}
	*out_rune = (int32_t)value;
	return need;
}

int32_t loke_rt_v1_utf8_valid(const uint8_t *data, int64_t len) {
	if (len < 0) {
		return 0;
	}
	int64_t offset = 0;
	while (offset < len) {
		int32_t decoded;
		int64_t used = loke_rt_v1_rune_at(data, len, offset, &decoded);
		if (used == 0) {
			return 0;
		}
		offset += used;
	}
	return 1;
}

int64_t loke_rt_v1_rune_count(const uint8_t *data, int64_t len) {
	int64_t offset = 0;
	int64_t count = 0;
	while (offset < len) {
		int32_t decoded;
		int64_t used = loke_rt_v1_rune_at(data, len, offset, &decoded);
		if (used == 0) {
			break; /* a validated string cannot get here */
		}
		offset += used;
		count += 1;
	}
	return count;
}

int64_t loke_rt_encode_rune(uint8_t *out, int32_t value) {
	uint32_t v = (uint32_t)value;
	if (value < 0 || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) {
		return 0;
	}
	if (v < 0x80) {
		out[0] = (uint8_t)v;
		return 1;
	}
	if (v < 0x800) {
		out[0] = (uint8_t)(0xC0 | (v >> 6));
		out[1] = (uint8_t)(0x80 | (v & 0x3F));
		return 2;
	}
	if (v < 0x10000) {
		out[0] = (uint8_t)(0xE0 | (v >> 12));
		out[1] = (uint8_t)(0x80 | ((v >> 6) & 0x3F));
		out[2] = (uint8_t)(0x80 | (v & 0x3F));
		return 3;
	}
	out[0] = (uint8_t)(0xF0 | (v >> 18));
	out[1] = (uint8_t)(0x80 | ((v >> 12) & 0x3F));
	out[2] = (uint8_t)(0x80 | ((v >> 6) & 0x3F));
	out[3] = (uint8_t)(0x80 | (v & 0x3F));
	return 4;
}

/* ------------------------------------------------------------ creation -- */

int32_t loke_rt_v1_string_from_bytes(
	loke_rt_string_v1 *out, const uint8_t *data, int64_t len, const loke_rt_allocator_v1 *a) {
	publish_empty(out);
	if (len < 0 || !loke_rt_v1_utf8_valid(data, len)) {
		return 0;
	}
	if (len == 0) {
		return 1; /* the empty value needs no storage */
	}
	uint8_t *bytes = allocate_buffer(out, len, a);
	if (bytes == 0) {
		return 0;
	}
	memcpy(bytes, data, (size_t)len);
	return 1;
}

/* design.md "string type conversions": `.copy()` "allocates, because the result
 * must own its bytes". The source is already valid UTF-8, so this does not
 * re-validate it. */
int32_t loke_rt_v1_string_clone(
	loke_rt_string_v1 *out, const uint8_t *data, int64_t len, const loke_rt_allocator_v1 *a) {
	publish_empty(out);
	if (len <= 0) {
		return 1;
	}
	uint8_t *bytes = allocate_buffer(out, len, a);
	if (bytes == 0) {
		return 0;
	}
	memcpy(bytes, data, (size_t)len);
	return 1;
}

int32_t loke_rt_v1_string_concat(
	loke_rt_string_v1 *out,
	const uint8_t *a_data, int64_t a_len,
	const uint8_t *b_data, int64_t b_len,
	const loke_rt_allocator_v1 *allocator) {
	publish_empty(out);
	int64_t total;
	/* A sum that is not representable is a failure, not a wrapped-negative
	 * length handed to the provider. */
	if (!loke_rt_v1_checked_add(a_len, b_len, &total)) {
		return 0;
	}
	if (total == 0) {
		return 1;
	}
	uint8_t *bytes = allocate_buffer(out, total, allocator);
	if (bytes == 0) {
		return 0;
	}
	if (a_len > 0) {
		memcpy(bytes, a_data, (size_t)a_len);
	}
	if (b_len > 0) {
		memcpy(bytes + a_len, b_data, (size_t)b_len);
	}
	return 1;
}

int32_t loke_rt_v1_string_from_runes(
	loke_rt_string_v1 *out, const int32_t *runes, int64_t count, const loke_rt_allocator_v1 *a) {
	publish_empty(out);
	int64_t total = 0;
	for (int64_t i = 0; i < count; i++) {
		uint8_t scratch[4];
		int64_t used = loke_rt_encode_rune(scratch, runes[i]);
		if (used == 0) {
			return 0;
		}
		total += used;
	}
	if (total == 0) {
		return 1;
	}
	uint8_t *bytes = allocate_buffer(out, total, a);
	if (bytes == 0) {
		return 0;
	}
	int64_t cursor = 0;
	for (int64_t i = 0; i < count; i++) {
		cursor += loke_rt_encode_rune(bytes + cursor, runes[i]);
	}
	return 1;
}

/* ---------------------------------------------------------- comparison -- */

/* design.md: "`string` and `string_view` values are comparable and ordered,
 * lexically byte-wise." */
int32_t loke_rt_v1_bytes_compare(
	const uint8_t *a_data, int64_t a_len, const uint8_t *b_data, int64_t b_len) {
	int64_t shared = a_len < b_len ? a_len : b_len;
	if (shared > 0) {
		int order = memcmp(a_data, b_data, (size_t)shared);
		if (order != 0) {
			return order < 0 ? -1 : 1;
		}
	}
	if (a_len == b_len) {
		return 0;
	}
	return a_len < b_len ? -1 : 1;
}

int64_t loke_rt_v1_cstring_len(const uint8_t *p) {
	if (p == 0) {
		return 0;
	}
	int64_t n = 0;
	while (p[n] != 0) {
		n += 1;
	}
	return n;
}
