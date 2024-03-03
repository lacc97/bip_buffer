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
            curr_head: usize,
            head: usize,
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

            // This is the region that immediately follows after the current value of head. It is limited by either tail or the end of the buffer.
            const end_0 = if (tail <= head) (b.data.len) else (tail - 1);
            const beg_0 = head;
            if ((end_0 - beg_0) >= count) return .{
                .data = b.data[beg_0..][0..count],
                .curr_head = head,
                .head = beg_0,
            };

            // This is the second region after wraparound of head, which can only happen if head is in front of tail.
            const end_1 = if (tail > 0) (tail - 1) else 0;
            const beg_1 = if (tail <= head) 0 else end_1;
            if ((end_1 - beg_1) >= count) return .{
                .data = b.data[beg_1..][0..count],
                .curr_head = head,
                .head = beg_1,
            };

            return error.OutOfMemory;
        }

        pub fn commit(b: *Buffer, r: Reservation, count: usize) void {
            if (comptime opts.safety_checks) if (!(r.data.len < b.data.len)) @panic("bad reservation");
            if (comptime opts.safety_checks) if (!(r.curr_head < b.data.len)) @panic("bad reservation");
            if (comptime opts.safety_checks) if (!(r.head < b.data.len)) @panic("bad reservation");
            if (comptime opts.safety_checks) if (!(count <= r.data.len)) @panic("bad commit count");

            const mark = b.mark;
            const head = b.head;

            if (comptime opts.safety_checks) if (!(r.curr_head == head)) @panic("already committed this reservation");

            const next_head = r.head + count;
            const tail = b.tail;

            const next_mark = if (tail <= head) (next_head) else @max(mark, r.curr_head);

            if (comptime opts.safety_checks) if (!(next_head < b.data.len)) @panic("BUG: inconsistent head value");
            if (comptime opts.safety_checks) if (!(next_mark >= b.tail)) @panic("BUG: inconsistent mark value");

            b.mark = next_mark;
            b.head = next_head;
        }
    };
}

test {
    const testing = std.testing;

    const storage = try testing.allocator.alloc(u8, 1024);
    defer testing.allocator.free(storage);

    var b = BipBufferUnmanaged(u8, .{}).init(storage);

    const r = try b.reserve(16);
    @memcpy(r.data[0..5], "Hello");
    b.commit(r, 16);

    try testing.expectEqualStrings("Hello", b.data[0..5]);
}
