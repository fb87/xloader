//! Tiny freestanding C-runtime compatibility for libfdt.
//! Keep this intentionally small; xloader itself does not use libc.

pub export fn memcpy(dst_: *anyopaque, src_: *const anyopaque, n: usize) *anyopaque {
    const dst: [*]volatile u8 = @ptrCast(dst_);
    const src: [*]const volatile u8 = @ptrCast(src_);
    var i: usize = 0;
    while (i < n) : (i += 1) dst[i] = src[i];
    return dst_;
}

pub export fn memmove(dst_: *anyopaque, src_: *const anyopaque, n: usize) *anyopaque {
    const dst_addr = @intFromPtr(dst_);
    const src_addr = @intFromPtr(src_);
    const dst: [*]volatile u8 = @ptrCast(dst_);
    const src: [*]const volatile u8 = @ptrCast(src_);

    if (dst_addr <= src_addr or dst_addr >= src_addr + n) {
        var i: usize = 0;
        while (i < n) : (i += 1) dst[i] = src[i];
    } else {
        var i: usize = n;
        while (i != 0) {
            i -= 1;
            dst[i] = src[i];
        }
    }
    return dst_;
}

pub export fn memset(dst_: *anyopaque, value: c_int, n: usize) *anyopaque {
    const dst: [*]volatile u8 = @ptrCast(dst_);
    const byte: u8 = @truncate(@as(c_uint, @bitCast(value)));
    var i: usize = 0;
    while (i < n) : (i += 1) dst[i] = byte;
    return dst_;
}

pub export fn memcmp(a_: *const anyopaque, b_: *const anyopaque, n: usize) c_int {
    const a: [*]const volatile u8 = @ptrCast(a_);
    const b: [*]const volatile u8 = @ptrCast(b_);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
    }
    return 0;
}

pub export fn strlen(s: [*:0]const u8) usize {
    var n: usize = 0;
    while (s[n] != 0) : (n += 1) {}
    return n;
}

pub export fn strnlen(s: [*]const u8, maxlen: usize) usize {
    var n: usize = 0;
    while (n < maxlen and s[n] != 0) : (n += 1) {}
    return n;
}

pub export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) c_int {
    var i: usize = 0;
    while (true) : (i += 1) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
        if (a[i] == 0) return 0;
    }
}

pub export fn strchr(s: [*:0]const u8, needle: c_int) ?[*:0]const u8 {
    const c: u8 = @truncate(@as(c_uint, @bitCast(needle)));
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == c) return @ptrCast(&s[i]);
        if (s[i] == 0) return null;
    }
}

pub export fn memchr(s_: *const anyopaque, needle: c_int, n: usize) ?*const anyopaque {
    const s: [*]const volatile u8 = @ptrCast(s_);
    const c: u8 = @truncate(@as(c_uint, @bitCast(needle)));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (s[i] == c) return @ptrCast(@volatileCast(&s[i]));
    }
    return null;
}

pub export fn strrchr(s: [*:0]const u8, needle: c_int) ?[*:0]const u8 {
    const c: u8 = @truncate(@as(c_uint, @bitCast(needle)));
    var last: ?[*:0]const u8 = null;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == c) last = @ptrCast(&s[i]);
        if (s[i] == 0) return last;
    }
}

pub export fn strncmp(a: [*]const u8, b: [*]const u8, n: usize) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] < b[i]) return -1;
        if (a[i] > b[i]) return 1;
        if (a[i] == 0) return 0;
    }
    return 0;
}

pub export fn __ubsan_handle_type_mismatch_v1(_: *const anyopaque, _: *const anyopaque) void {}
pub export fn __ubsan_handle_pointer_overflow(_: *const anyopaque, _: usize, _: usize) void {}
pub export fn __ubsan_handle_shift_out_of_bounds(_: *const anyopaque, _: usize, _: usize) void {}
pub export fn __ubsan_handle_sub_overflow(_: *const anyopaque, _: usize, _: usize) void {}
pub export fn __ubsan_handle_add_overflow(_: *const anyopaque, _: usize, _: usize) void {}
pub export fn __ubsan_handle_negate_overflow(_: *const anyopaque, _: usize) void {}
pub export fn __ubsan_handle_divrem_overflow(_: *const anyopaque, _: usize, _: usize) void {}
