const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;

pub const Options = struct {
    safety_checks: bool = (builtin.mode == .Debug or builtin.mode == .ReleaseSafe),
};

fn BipBufferUnmanaged(comptime T: type, comptime opts: Options) type {
    return struct {
        const Buffer = @This();

        data: []T,
        mark: usize,
        head: usize,
        tail: usize,

        pub const Reservation = struct {
            data: []T,
            head: usize,
            next_head: usize,
        };

        pub fn init(buf: []T) Buffer {
            return .{
                .data = buf,
                .mark = buf.len,
                .head = 0,
                .tail = 0,
            };
        }

        pub fn reset(b: *Buffer) void {
            const buf = b.data;
            b.* = init(buf);
        }

        pub fn reserve(b: *Buffer, count: usize) error{OutOfMemory}!Reservation {
            if (comptime opts.safety_checks) if (!(count > 0)) @panic("bad reserve count");

            const head = b.head;
            const tail = b.tail;

            const available_regions = availableWriteRegions(b.data, head, tail);
            if (available_regions[0].len >= count) return .{
                .data = available_regions[0][head..][0..count],
                .head = head,
                .next_head = head,
            };
            if (available_regions[1].len >= count) return .{
                .data = available_regions[1][0..count],
                .head = head,
                .next_head = 0,
            };

            return error.OutOfMemory;
        }

        pub fn commit(b: *Buffer, r: Reservation, count: usize) void {
            if (comptime opts.safety_checks) if (!(r.data.len < b.data.len)) @panic("bad reservation");
            if (comptime opts.safety_checks) if (!(r.head < b.data.len)) @panic("bad reservation");
            if (comptime opts.safety_checks) if (!(r.next_head < b.data.len)) @panic("bad reservation");
            if (comptime opts.safety_checks) if (!(count <= r.data.len)) @panic("bad commit count");

            const head = b.head;
            const tail = b.tail;

            if (comptime opts.safety_checks) if (!(r.head == head)) @panic("already committed this reservation");

            const available_regions = availableWriteRegions(b.data, head, tail);
            if (comptime opts.safety_checks) if (!(count <= available_regions[0].len or count <= available_regions[1].len)) @panic("bad reservation");

            b.mark = if ((b.data.len - head) >= r.data.len) (r.next_head + count) else (r.next_head);
            b.head = r.next_head + count;
        }

        inline fn availableWriteRegions(data: []T, head: usize, tail: usize) [2][]T {
            const available_0 = blk: {
                const end = if (tail <= head) (data.len) else (tail - 1);
                break :blk end - head;
            };
            const available_1 = blk: {
                const end = if (tail > 0) (tail - 1) else 0;
                const beg = if (tail <= head) 0 else end;
                break :blk end - beg;
            };

            return .{ data[head..][0..available_0], data[0..available_1] };
        }
    };
}

test {
    const testing = std.testing;

    const storage = try testing.allocator.alloc(u8, 1024);
    defer testing.allocator.free(storage);

    var b = BipBufferUnmanaged(u8, .{}).init(storage);

    const r = try b.reserve(16);
    b.commit(r, 17);
}
