const std = @import("std");
const assert = std.debug.assert;

fn BipBufferUnmanaged(comptime T: type) type {
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
            next_mark: usize,
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

        pub noinline fn reserve(b: *Buffer, count: usize) error{OutOfMemory}!Reservation {
            assert(count > 0); // Bad reserve count.

            const head = b.head;
            const tail = b.tail;

            const available_regions = availableRegions(b.data, head, tail);
            if (available_regions[0].len >= count) return .{
                .data = available_regions[0][0..count],
                .head = head,
                .next_head = head,
                .next_mark = if (tail <= head) b.data.len else b.mark,
            };
            if (available_regions[1].len >= count) return .{
                .data = available_regions[1][0..count],
                .head = head,
                .next_head = 0,
                .next_mark = if (tail <= head) b.data.len else b.mark,
            };

            return error.OutOfMemory;
        }

        pub fn commit(b: *Buffer, r: Reservation, count: usize) void {
            assert(count <= r.data.len); // Bad commit count.

            const head = b.head;
            _ = head; // autofix
            const tail = b.tail;
            _ = tail; // autofix

            b.mark = r.next_mark;
            b.head = r.next_head + count;
        }

        inline fn availableRegions(data: []T, head: usize, tail: usize) [2][]T {
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

    var b = BipBufferUnmanaged(u8).init(storage);

    const r = try b.reserve(16);
    b.commit(r, 17);
}
