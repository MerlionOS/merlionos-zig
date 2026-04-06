// Compiler-required memory builtins for freestanding.

export fn memcpy(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    for (0..len) |i| {
        dest[i] = src[i];
    }
    return dest;
}

export fn memmove(dest: [*]u8, src: [*]const u8, len: usize) [*]u8 {
    if (@intFromPtr(dest) < @intFromPtr(src)) {
        for (0..len) |i| {
            dest[i] = src[i];
        }
    } else {
        var i = len;
        while (i > 0) {
            i -= 1;
            dest[i] = src[i];
        }
    }
    return dest;
}

export fn memset(dest: [*]u8, val: i32, len: usize) [*]u8 {
    const byte: u8 = @intCast(val & 0xFF);
    for (0..len) |i| {
        dest[i] = byte;
    }
    return dest;
}

export fn memcmp(s1: [*]const u8, s2: [*]const u8, len: usize) i32 {
    for (0..len) |i| {
        if (s1[i] != s2[i]) {
            return @as(i32, s1[i]) - @as(i32, s2[i]);
        }
    }
    return 0;
}
