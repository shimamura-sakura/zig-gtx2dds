const std = @import("std");

fn Slice(comptime T: anytype) type {
    return struct {
        const Self = @This();
        const Error = error{EOF};
        left: T,
        pub fn take(self: *Self, n: anytype) Error!@TypeOf(self.left[0..n]) {
            if (self.left.len < n) return Error.EOF;
            defer self.left = self.left[n..];
            return self.left[0..n];
        }
    };
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    // arg
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();
    _ = args.next();
    const i_filename = args.next() orelse return error.NoArg;
    // load
    const dat = try std.fs.cwd().readFileAlloc(alloc, i_filename, 1048576 * 16);
    defer alloc.free(dat);
    var slice = Slice([]const u8){ .left = dat };
    // test 1
    try std.testing.expectEqualStrings("GTX\x01", try slice.take(4));
    const size_1 = std.mem.readInt(u32, try slice.take(4), .little);
    try std.testing.expectEqual(0, std.mem.readInt(u32, try slice.take(4), .little));
    const size_2 = std.mem.readInt(u32, try slice.take(4), .little);
    try std.testing.expectEqual(dat.len, size_1 + size_2);
    const size_3 = std.mem.readInt(u32, try slice.take(4), .little);
    try std.testing.expectEqual(size_1, size_3 + 0x10);
    try std.testing.expectEqualSlices(u8, &(.{0} ** 20), try slice.take(20));
    const size_4 = std.mem.readInt(u32, try slice.take(4), .little);
    const size_5 = std.mem.readInt(u32, try slice.take(4), .little);
    try std.testing.expect(size_4 + 1 == size_5);
    try std.testing.expectEqual(4, std.mem.readInt(u32, try slice.take(4), .little));
    _ = try slice.take((size_5 + 3) >> 2 << 2);
    try std.testing.expectEqual(size_1, @intFromPtr(slice.left.ptr) - @intFromPtr(dat.ptr));
    // test 2
    try std.testing.expectEqualStrings(&.{ 0x00, 0x05, 0x07, 0x00 }, try slice.take(4));
    const size_6 = std.mem.readInt(u32, try slice.take(4), .little);
    const size_7 = std.mem.readInt(u32, try slice.take(4), .little);
    try std.testing.expect(size_6 + 1 == size_7);
    try std.testing.expectEqual(0x3c, std.mem.readInt(u32, try slice.take(4), .little)); // from 0x3c to string (0x3c bytes)
    try std.testing.expectEqual(0x000002, std.mem.readInt(u32, try slice.take(4), .little));
    try std.testing.expectEqual(0x040001, std.mem.readInt(u32, try slice.take(4), .little));
    const imag_w = std.mem.readInt(u32, try slice.take(4), .little);
    try std.testing.expect(imag_w > 0 and std.math.isPowerOfTwo(imag_w));
    const imag_h = std.mem.readInt(u32, try slice.take(4), .little);
    try std.testing.expect(imag_h > 0 and std.math.isPowerOfTwo(imag_h));
    const l_size = std.mem.readInt(u32, try slice.take(4), .little);
    try std.testing.expect(imag_w * 4 == l_size); // maybe line RGBA size in bytes
    try std.testing.expectEqual(1, std.mem.readInt(u32, try slice.take(4), .little));
    // test 3
    const pixfmt = try slice.take(4);
    const some_i = std.mem.readInt(u32, try slice.take(4), .little);
    // print
    if (std.mem.eql(u8, pixfmt, "UBC1"))
        try std.testing.expectEqual(8, some_i)
    else if (std.mem.eql(u8, pixfmt, "UBC3")) {
        if (true)
            _ = "note: failed on ITEM_HEAD203.gtx"
        else
            try std.testing.expectEqual(16, some_i);
    } else return error.UnknownPixFmt;
    try std.testing.expectEqual(1, std.mem.readInt(u32, try slice.take(4), .little));
    try std.testing.expectEqual(0, std.mem.readInt(u32, try slice.take(4), .little));
    try std.testing.expectEqual(0, std.mem.readInt(u32, try slice.take(4), .little));
    try std.testing.expectEqual(0, std.mem.readInt(u32, try slice.take(4), .little));
    const datasize = std.mem.readInt(u32, try slice.take(4), .little);
    if (std.mem.eql(u8, pixfmt, "UBC1"))
        try std.testing.expectEqual(imag_w * imag_h, datasize * 2)
    else if (std.mem.eql(u8, pixfmt, "UBC3"))
        try std.testing.expectEqual(imag_w * imag_h * 1, datasize);
    const size_8 = std.mem.readInt(u32, try slice.take(4), .little);
    try std.testing.expectEqual(size_8, ((size_7 + 3) >> 2 << 2) + 4);
    _ = try slice.take(size_8 - 4);
    try std.testing.expectEqual(datasize, slice.left.len);
}
