const std = @import("std");
const builtin = @import("builtin");

pub fn panic(_: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    unreachable;
}

pub fn main() !u8 {
    realMain() catch |e| {
        _ = std.io.getStdErr().write(switch (e) {
            error.Usage => "usage: program <infile> <outfile>\n",
            error.EOF => "unexpected EOF\n",
            error.OutOfMemory => "out of memory\n",
            error.UnkIFile => "unknown input file\n",
            error.UnkPixFmt => "unknown pixel format\n",
            error.ErrIFile => "error reading input file\n",
            error.ErrOFile => "error writing output file\n",
            error.PowOfTwo => "todo: dimension not power of two\n",
        }) catch {};
        return 1;
    };
    return 0;
}

fn realMain() !void {
    const alloc = std.heap.page_allocator;
    // args
    var argIter = std.process.argsWithAllocator(alloc) catch return error.Usage;
    defer argIter.deinit();
    _ = argIter.next();
    const i_filename = argIter.next() orelse &.{};
    const o_filename = argIter.next() orelse return error.Usage;
    // i file
    const i_file = std.fs.cwd().openFile(i_filename, .{}) catch return error.ErrIFile;
    defer i_file.close();
    const i_data = try alloc.alloc(u8, @intCast(i_file.getEndPos() catch return error.ErrIFile));
    defer alloc.free(i_data);
    _ = i_file.readAll(i_data) catch return error.ErrIFile;
    // o file
    const o_file = std.fs.cwd().createFile(o_filename, .{}) catch return error.ErrOFile;
    defer o_file.close();
    // main
    var slice: Slice([]const u8) = .{ .left = i_data };
    const mag = try slice.take(4);
    const imag_w, const imag_h, const blkSz, const iPix, const unswiz = if (std.mem.eql(u8, mag, "GTX\x01")) label: {
        const header_size = std.mem.readInt(u32, try slice.take(4), .little);
        const follow_data = (try slice.take(header_size + 0x40))[header_size..][0..0x40];
        const nlen_padded = (std.mem.readInt(u32, follow_data[0..4], .little) + 3) & ~@as(u32, 3);
        _ = try slice.take(nlen_padded); // name string
        const imag_w = std.mem.readInt(u32, follow_data[16..20], .little);
        const imag_h = std.mem.readInt(u32, follow_data[20..24], .little);
        try checkPowerTwo(imag_w, imag_h);
        const dataSz, const blkSz, const pixFmt = try calcLenBlock(follow_data[32..36], imag_w, imag_h);
        var dds_header = dds_template;
        std.mem.writeInt(u32, dds_header[12..16], imag_h, .little);
        std.mem.writeInt(u32, dds_header[16..20], imag_w, .little);
        std.mem.writeInt(u32, dds_header[20..24], dataSz, .little);
        @memcpy(dds_header[84..88], &pixFmt);
        const data = try slice.take(dataSz);
        o_file.writeAll(&dds_header) catch return error.ErrOFile;
        break :label .{ imag_w, imag_h, blkSz, data, true };
    } else if (std.mem.eql(u8, mag, "DDS ")) label: {
        slice.left = i_data;
        const dds_header = try slice.take(128);
        const imag_h = std.mem.readInt(u32, dds_header[12..16], .little);
        const imag_w = std.mem.readInt(u32, dds_header[16..20], .little);
        try checkPowerTwo(imag_w, imag_h);
        const dataSz, const blkSz, const pixFmt = try calcLenBlock(dds_header[84..88], imag_w, imag_h);
        var gtx_header = gtx_template;
        std.mem.writeInt(u32, gtx_header[0x90..0x94], imag_w, .little);
        std.mem.writeInt(u32, gtx_header[0x94..0x98], imag_h, .little);
        std.mem.writeInt(u32, gtx_header[0x98..0x9c], imag_w << 2, .little);
        std.mem.writeInt(u32, gtx_header[0x0C..0x10], dataSz + 0x58, .little);
        std.mem.writeInt(u32, gtx_header[0xB8..0xBC], dataSz + 0x00, .little);
        @memcpy(gtx_header[0xA0..0xA4], &pixFmt);
        const data = try slice.take(dataSz);
        o_file.writeAll(&gtx_header) catch return error.ErrOFile;
        break :label .{ imag_w, imag_h, blkSz, data, false };
    } else return error.UnkIFile;
    // swiz
    const oPix = try alloc.alloc(u8, iPix.len);
    defer alloc.free(oPix);
    const blk_w = imag_w / 4;
    const blk_h = imag_h / 4;
    if (unswiz) {
        for (0..iPix.len / blkSz) |i| {
            const j = unSwizzle(u32, @intCast(i), blk_w, blk_h);
            @memcpy(oPix.ptr + j * blkSz, iPix.ptr[i * blkSz ..][0..blkSz]);
        }
    } else {
        for (0..iPix.len / blkSz) |i| {
            const j = unSwizzle(u32, @intCast(i), blk_w, blk_h);
            @memcpy(oPix.ptr + i * blkSz, iPix.ptr[j * blkSz ..][0..blkSz]);
        }
    }
    o_file.writeAll(oPix) catch return error.ErrOFile;
}

// utility

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

fn checkPowerTwo(w: u32, h: u32) error{PowOfTwo}!void {
    if (!std.math.isPowerOfTwo(w)) return error.PowOfTwo;
    if (!std.math.isPowerOfTwo(h)) return error.PowOfTwo;
}

fn calcLenBlock(pixfmt: *const [4]u8, w: u32, h: u32) error{UnkPixFmt}!struct { u32, u8, [4]u8 } {
    if (std.mem.eql(u8, pixfmt, "UBC1")) return .{ w * h >> 1, 8, "DXT1".* };
    if (std.mem.eql(u8, pixfmt, "DXT1")) return .{ w * h >> 1, 8, "UBC1".* };
    if (std.mem.eql(u8, pixfmt, "UBC3")) return .{ w * h, 16, "DXT5".* };
    if (std.mem.eql(u8, pixfmt, "DXT5")) return .{ w * h, 16, "UBC3".* };
    return error.UnkPixFmt;
}

// dds

const pppp: u8 = 0x00;
const dds_template = [128]u8{
    0x44, 0x44, 0x53, 0x20, 0x7C, 0x00, 0x00, 0x00, 0x07, 0x10, 0x08, 0x00, pppp, pppp, pppp, pppp,
    pppp, pppp, pppp, pppp, pppp, pppp, pppp, pppp, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, pppp, pppp, pppp, pppp, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

// gtx

const gtx_template = [208]u8{
    0x47, 0x54, 0x58, 0x01, 0x78, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4C, 0x2B, 0x35, 0x38,
    0x68, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x00,
    0x04, 0x00, 0x00, 0x00, 0x4C, 0x6F, 0x72, 0x65, 0x6D, 0x20, 0x69, 0x70, 0x73, 0x75, 0x6D, 0x20,
    0x64, 0x6F, 0x6C, 0x6F, 0x72, 0x20, 0x73, 0x69, 0x74, 0x20, 0x61, 0x6D, 0x65, 0x74, 0x2C, 0x20,
    0x63, 0x6F, 0x6E, 0x73, 0x65, 0x63, 0x74, 0x65, 0x74, 0x75, 0x72, 0x20, 0x61, 0x64, 0x69, 0x70,
    0x69, 0x73, 0x63, 0x69, 0x6E, 0x67, 0x20, 0x65, 0x6C, 0x69, 0x74, 0x2E, 0x20, 0x4E, 0x75, 0x6C,
    0x6C, 0x61, 0x6D, 0x20, 0x73, 0x00, 0x00, 0x00, 0x00, 0x05, 0x07, 0x00, 0x0F, 0x00, 0x00, 0x00,
    0x10, 0x00, 0x00, 0x00, 0x3C, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x00, 0x04, 0x00,
    0x49, 0x4D, 0x57, 0x5F, 0x49, 0x4D, 0x48, 0x5F, 0x57, 0x78, 0x34, 0x5F, 0x01, 0x00, 0x00, 0x00,
    0x55, 0x42, 0x43, 0x78, 0x08, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x44, 0x4C, 0x45, 0x4E, 0x14, 0x00, 0x00, 0x00,
    0x65, 0x64, 0x20, 0x6E, 0x75, 0x6E, 0x63, 0x20, 0x70, 0x75, 0x72, 0x75, 0x73, 0x2E, 0x28, 0x00,
};

// swiz

fn bitMasks(comptime T: type) [@ctz(@as(u8, @bitSizeOf(T)))]T {
    comptime var array: [@ctz(@as(u8, @bitSizeOf(T)))]T = undefined;
    comptime var index: comptime_int = array.len - 1;
    comptime var shift = @bitSizeOf(T) / 2;
    comptime var value = @as(T, 0) -% 1;
    inline while (index >= 0) : (index -= 1) {
        value = value ^ (value << shift);
        shift = shift >> 1;
        array[index] = value;
    }
    return array;
}

fn compactBits(comptime T: type, v: T) T {
    const masks = comptime bitMasks(T);
    var x = v & masks[0];
    inline for (masks[1..], 0..) |m, i| x = (x ^ (x >> (1 << i))) & m;
    return x;
}

pub fn unSwizzle(comptime T: type, i: T, w: T, h: T) T {
    const m = @min(w, h);
    const k: std.math.Log2Int(T) = @intCast(@ctz(m));
    if (h < w) {
        const j = i >> (2 * k) << (2 * k) | (compactBits(T, i >> 1) & (m - 1)) << k | (compactBits(T, i) & (m - 1)) << 0;
        return (j % h) * w + (j / h);
    } else return i >> (2 * k) << (2 * k) | (compactBits(T, i) & (m - 1)) << k | (compactBits(T, i >> 1) & (m - 1)) << 0;
}
