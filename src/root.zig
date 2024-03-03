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
            if (!(buf.len > 0)) @panic("empty buffer");

            return .{
                .data = buf,
                .mark = 0,
                .head = 0,
                .tail = 0,
            };
        }

        pub fn reset(b: *Buffer) void {
            const buf = b.data;
            b.* = init(buf);
        }

        pub fn totalAvailableForWrite(b: *const Buffer) usize {
            const head = b.head;
            if (comptime opts.safety_checks) if (!(head < b.data.len)) @panic("BUG: inconsistent head value");
            const tail = b.tail;
            if (comptime opts.safety_checks) if (!(tail < b.data.len)) @panic("BUG: inconsistent tail value");

            // This is the region that immediately follows after the current value of head, limited by either tail or the end of the buffer.
            const end_0 = if (tail <= head) (b.data.len - 1) else (tail - 1);
            const beg_0 = head;

            // This is the second region after wraparound of head, which can only happen if head is in front of tail.
            const end_1 = if (tail > 0) (tail) else 0;
            const beg_1 = if (tail <= head) 0 else end_1;

            return (end_0 - beg_0) + (end_1 - beg_1);
        }

        pub fn totalAvailableForRead(b: *const Buffer) usize {
            const mark = b.mark;
            if (comptime opts.safety_checks) if (!(mark < b.data.len)) @panic("BUG: inconsistent mark value");
            const head = b.head;
            if (comptime opts.safety_checks) if (!(head < b.data.len)) @panic("BUG: inconsistent head value");
            const tail = b.tail;
            if (comptime opts.safety_checks) if (!(tail < b.data.len)) @panic("BUG: inconsistent tail value");

            // This is the region that immediately follows after the current value of tail, limited by head or mark.
            const end_0 = if (tail <= head) (head) else (mark);
            const beg_0 = tail;

            // This is the second region after wraparound of tail, which can only happen if tail is in front of head.
            const end_1 = if (tail <= head) (0) else (head);
            const beg_1 = if (tail <= head) (end_1) else (0);

            return (end_0 - beg_0) + (end_1 - beg_1);
        }

        pub fn reserve(b: *Buffer, count: usize) error{OutOfMemory}!Reservation {
            if (comptime opts.safety_checks) if (!(count > 0)) @panic("bad reserve count");

            const head = b.head;
            if (comptime opts.safety_checks) if (!(head < b.data.len)) @panic("BUG: inconsistent head value");
            const tail = b.tail;
            if (comptime opts.safety_checks) if (!(tail < b.data.len)) @panic("BUG: inconsistent tail value");

            // This is the region that immediately follows after the current value of head. It is limited by either tail or the end of the buffer.
            const end_0 = if (tail <= head) (b.data.len - 1) else (tail - 1);
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
            if (count == 0) return;

            const mark = b.mark;
            if (comptime opts.safety_checks) if (!(mark < b.data.len)) @panic("BUG: inconsistent mark value");
            const head = b.head;
            if (comptime opts.safety_checks) if (!(head < b.data.len)) @panic("BUG: inconsistent head value");

            if (comptime opts.safety_checks) if (!(r.data.len < b.data.len)) @panic("bad reservation");
            if (comptime opts.safety_checks) if (!(r.curr_head < b.data.len)) @panic("bad reservation");
            if (comptime opts.safety_checks) if (!(r.head < b.data.len)) @panic("bad reservation");
            if (comptime opts.safety_checks) if (!(count <= r.data.len)) @panic("bad commit count");

            if (comptime opts.safety_checks) if (!(r.curr_head == head)) @panic("already committed this reservation");

            const next_head = r.head + count;
            if (comptime opts.safety_checks) if (!(next_head < b.data.len)) @panic("BUG: inconsistent head value");

            const tail = b.tail;
            if (comptime opts.safety_checks) if (!(tail < b.data.len)) @panic("BUG: inconsistent tail value");

            // Set mark when wraparound, otherwise keep up with head.
            const next_mark = if (next_head <= head) (head) else @max(mark, next_head);
            if (comptime opts.safety_checks) if (!(next_mark >= tail)) @panic("BUG: inconsistent mark value");

            b.mark = next_mark;
            b.head = next_head;
        }

        pub fn peek(b: *const Buffer) []const u8 {
            const mark = b.mark;
            if (comptime opts.safety_checks) if (!(mark < b.data.len)) @panic("BUG: inconsistent mark value");
            const head = b.head;
            if (comptime opts.safety_checks) if (!(head < b.data.len)) @panic("BUG: inconsistent head value");
            const tail = b.tail;
            if (comptime opts.safety_checks) if (!(tail < b.data.len)) @panic("BUG: inconsistent tail value");

            const end = if (tail <= head) (head) else (mark);
            return b.data[tail..end];
        }

        pub fn consume(b: *Buffer, count: usize) void {
            if (count == 0) return;

            const mark = b.mark;
            if (comptime opts.safety_checks) if (!(mark < b.data.len)) @panic("BUG: inconsistent mark value");
            const head = b.head;
            if (comptime opts.safety_checks) if (!(head < b.data.len)) @panic("BUG: inconsistent head value");
            const tail = b.tail;
            if (comptime opts.safety_checks) if (!(tail < b.data.len)) @panic("BUG: inconsistent tail value");

            const end = if (tail <= head) (head) else (mark);
            if (comptime opts.safety_checks) if (!((end - tail) >= count)) @panic("bad consume count");

            // Wrap around only in the case where we are in front of head and we have reached the mark.
            const next_tail = if (tail <= head or count < (end - tail)) (tail + count) else 0;
            if (comptime opts.safety_checks) if (!(next_tail < b.data.len)) @panic("BUG: inconsistent tail value");

            b.tail = next_tail;
        }
    };
}

test {
    const testing = std.testing;

    const storage = try testing.allocator.alloc(u8, 17);
    defer testing.allocator.free(storage);

    var b = BipBufferUnmanaged(u8, .{}).init(storage);
    try testing.expectEqual(@as(usize, 16), b.totalAvailableForWrite());
    try testing.expectEqual(@as(usize, 0), b.totalAvailableForRead());

    {
        const r = try b.reserve(16);
        @memcpy(r.data[0..5], "Hello");
        b.commit(r, 5);
        try testing.expectEqual(@as(usize, 11), b.totalAvailableForWrite());
        try testing.expectEqual(@as(usize, 5), b.totalAvailableForRead());

        const peeked = b.peek();
        try testing.expectEqualStrings("Hello", peeked);
        b.consume(5);
    }

    try testing.expectEqual(@as(usize, 16), b.totalAvailableForWrite());
    try testing.expectEqual(@as(usize, 0), b.totalAvailableForRead());

    {
        try testing.expectError(error.OutOfMemory, b.reserve(16));
        const r0 = try b.reserve(11);
        @memcpy(r0.data[0..8], ", World!");
        b.commit(r0, 8);
        try testing.expectEqual(@as(usize, 8), b.totalAvailableForWrite());
        try testing.expectEqual(@as(usize, 8), b.totalAvailableForRead());

        // This one will leave a mark at 13 because there is only 3 spaces left at the end of the ring.
        const r1 = try b.reserve(4);
        @memcpy(r1.data[0..4], "!!!!");
        b.commit(r1, 4);
        try testing.expectEqual(@as(usize, 0), b.totalAvailableForWrite());
        try testing.expectEqual(@as(usize, 12), b.totalAvailableForRead());

        const p1 = b.peek();
        try testing.expectEqualStrings(", World!", p1);
        b.consume(2);
        try testing.expectEqual(@as(usize, 2), b.totalAvailableForWrite());
        try testing.expectEqual(@as(usize, 10), b.totalAvailableForRead());

        const p2 = b.peek();
        try testing.expectEqualStrings("World!", p2);
        // This bumps up tail past the mark and wraps it around, so we recover the full buffer for writes past it.
        b.consume(p2.len);
        try testing.expectEqual(@as(usize, 12), b.totalAvailableForWrite());
        try testing.expectEqual(@as(usize, 4), b.totalAvailableForRead());

        const p3 = b.peek();
        try testing.expectEqualStrings("!!!!", p3);
        b.consume(p3.len);
        try testing.expectEqual(@as(usize, 16), b.totalAvailableForWrite());
        try testing.expectEqual(@as(usize, 0), b.totalAvailableForRead());

        try testing.expectEqual(@as(usize, 13), b.mark);
        try testing.expectEqual(@as(usize, 4), b.head);
        try testing.expectEqual(@as(usize, 4), b.tail);
    }
}
