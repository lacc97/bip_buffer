const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;

pub const Options = struct {
    safety_checks: bool = (builtin.mode == .Debug or builtin.mode == .ReleaseSafe),
    single_threaded: bool = builtin.single_threaded,
};

pub fn BipBufferUnmanaged(comptime T: type, comptime opts: Options) type {
    return struct {
        const Buffer = @This();

        data: []T,
        mark: usize,
        head: usize,
        tail: usize,

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

        pub fn reserveExact(b: *Buffer, count: usize) ?Reserve {
            const r = b.reserveLargest(count);
            return if (r.data.len == count) r else null;
        }

        pub fn reserveLargest(b: *Buffer, count: usize) Reserve {
            // We are the writing thread so we can load head unordered.
            const head = load(&b.head, .unordered);
            check(head < b.data.len, "BUG: inconsistent head pointer value");

            // Load acquire to synchronise with the reading thread.
            const tail = load(&b.tail, .acquire);
            check(tail < b.data.len, "BUG: inconsistent tail pointer value");

            if (head < tail) {
                // We are the writing thread so we can load mark unordered.
                const mark = load(&b.mark, .unordered);
                check(mark <= b.data.len, "BUG: inconsistent mark pointer value");
                check(head <= mark, "BUG: inconsistent mark and head pointer value");

                const len = @min(count, tail - head - 1);
                return .{
                    .data = b.data[head..][0..len],
                    .__bb = b,
                    .__head = head,
                    .__mark = mark,
                    .__mark_shift = false,
                };
            } else {
                const end = if (tail != 0) (b.data.len) else (b.data.len - 1);
                if ((end - head) >= count) {
                    return .{
                        .data = b.data[head..][0..count],
                        .__bb = b,
                        .__head = head,
                        .__mark = head,
                        .__mark_shift = true,
                    };
                } else {
                    // Wrap around.
                    const len = if (tail > 0) @min(count, tail - 1) else 0;
                    return .{
                        .data = b.data[0..][0..len],
                        .__bb = b,
                        .__head = 0,
                        .__mark = head,
                        .__mark_shift = false,
                    };
                }
            }
        }

        pub const Reserve = struct {
            data: []T,

            __bb: *Buffer,

            /// Copy of the head pointer at the time of reserve.
            __head: usize,

            /// The next base value for the mark pointer.
            __mark: usize,

            /// Whether we need to shift the mark pointer at commit.
            __mark_shift: bool,

            pub fn commit(r: Reserve, count: usize) void {
                check(count <= r.data.len, "bad commit count");

                if (count == 0) return;

                const next_mark = r.__mark + if (r.__mark_shift) (count) else (0);
                const next_head = blk: {
                    var next = r.__head + count;
                    if (next == r.__bb.data.len) next = 0;
                    break :blk next;
                };

                check(next_head < r.__bb.data.len, "BUG: inconsistent head pointer value");
                check(next_mark <= r.__bb.data.len, "BUG: inconsistent mark pointer value");
                check(next_head <= next_mark, "BUG: inconsistent mark and head pointer value");
                store(&r.__bb.mark, next_mark, .unordered);
                store(&r.__bb.head, next_head, .release);
            }
        };

        pub fn peek(b: *Buffer) Peek {
            // We are the reading thread so we can load tail unordered.
            const tail = load(&b.tail, .unordered);
            check(tail < b.data.len, "BUG: inconsistent tail pointer value");

            const head = load(&b.head, .acquire);
            check(head < b.data.len, "BUG: inconsistent head pointer value");

            if (head >= tail) {
                return .{
                    .data = b.data[tail..head],
                    .__bb = b,
                    .__tail = tail,
                    .__wrap = false,
                };
            } else {
                // Tail is further than head, which means mark cannot be changed until tail wraps around.
                // This means loading head acquire (which we already did) is correct.
                const mark = load(&b.mark, .unordered);
                check(mark <= b.data.len, "BUG: inconsistent mark pointer value");
                check(head <= mark, "BUG: inconsistent mark and head pointer value");

                return if (tail == mark) .{
                    .data = b.data[0..head],
                    .__bb = b,
                    .__tail = 0,
                    .__wrap = false,
                } else .{
                    .data = b.data[tail..mark],
                    .__bb = b,
                    .__tail = tail,
                    .__wrap = true,
                };
            }
        }
        pub const Peek = struct {
            data: []T,

            __bb: *Buffer,

            // Copy of the tail pointer at the time of peeking.
            __tail: usize,

            // Whether a full consume will trigger wrapping on the tail pointer.
            __wrap: bool,

            pub fn consume(p: Peek, count: usize) void {
                check(count <= p.data.len, "bad consume count");

                if (count == 0) return;

                const next_tail = blk: {
                    var next = p.__tail + count;
                    if (p.__wrap and count == p.data.len) next = 0;
                    break :blk next;
                };
                check(next_tail < p.__bb.data.len, "BUG: inconsistent tail pointer value");
                store(&p.__bb.tail, next_tail, .release);
            }
        };

        inline fn check(b: bool, comptime msg: []const u8) void {
            if (comptime opts.safety_checks) if (!b) @panic(msg);
        }

        inline fn load(p: *const usize, ordering: std.builtin.AtomicOrder) usize {
            var v: usize = undefined;
            if (comptime opts.single_threaded) {
                v = p.*;
            } else {
                v = @atomicLoad(usize, p, ordering);
            }
            return v;
        }

        inline fn store(p: *usize, v: usize, ordering: std.builtin.AtomicOrder) void {
            if (comptime opts.single_threaded) {
                p.* = v;
            } else {
                @atomicStore(usize, p, v, ordering);
            }
        }
    };
}

test {
    const testing = std.testing;

    const types = .{
        BipBufferUnmanaged(u8, .{ .single_threaded = false }),
        BipBufferUnmanaged(u8, .{ .single_threaded = true }),
    };

    inline for (types) |B| {
        const storage = try testing.allocator.alloc(u8, 17);
        defer testing.allocator.free(storage);

        var b = B.init(storage);

        {
            const r = b.reserveExact(16) orelse return error.OutOfSpace;
            @memcpy(r.data[0..5], "Hello");
            r.commit(5);

            const peeked = b.peek();
            try testing.expectEqualStrings("Hello", peeked.data);
            peeked.consume(5);
        }

        {
            try testing.expectEqual(@as(?B.Reserve, null), b.reserveExact(16));
            const r0 = b.reserveExact(11) orelse return error.OutOfSpace;
            @memcpy(r0.data[0..9], ", World!!");
            r0.commit(9);

            // This one will leave a mark at 14 because there is only 3 spaces left at the end of the ring.
            const r1 = b.reserveExact(4) orelse return error.OutOfSpace;
            @memcpy(r1.data[0..4], "!!!!");
            r1.commit(4);

            const p1 = b.peek();
            try testing.expectEqualStrings(", World!!", p1.data);
            p1.consume(2);

            const p2 = b.peek();
            try testing.expectEqualStrings("World!!", p2.data);
            // This bumps up tail past the mark and wraps it around, so we recover the full buffer for writes past it.
            p2.consume(p2.data.len);

            const p3 = b.peek();
            try testing.expectEqualStrings("!!!!", p3.data);
            p3.consume(p3.data.len);

            try testing.expectEqual(@as(usize, 14), b.mark);
            try testing.expectEqual(@as(usize, 4), b.head);
            try testing.expectEqual(@as(usize, 4), b.tail);
        }
    }
}

test "multithreaded" {
    const testing = std.testing;

    const iteration_count = 100_000_000;
    const bb_size = 600;

    const BB = BipBufferUnmanaged(u8, .{ .single_threaded = false });

    const producer = struct {
        fn producer(bb: *BB, arg_rng_state: std.Random.DefaultPrng, count: usize) !void {
            var rng_state = arg_rng_state;
            const rng = rng_state.random();

            var i: usize = 0;
            while (i < count) {
                const reserve_count = rng.intRangeLessThan(usize, 1, bb_size / 2);

                const reservation = spin: while (true) break :spin bb.reserveExact(reserve_count) orelse continue :spin;
                for (reservation.data, 0..) |*out, j| out.* = @truncate(i + j);

                const commit_count = rng.intRangeLessThan(usize, 0, reserve_count);
                reservation.commit(commit_count);

                i += commit_count;
            }
        }
    }.producer;

    const consumer = struct {
        fn consumer(bb: *BB, arg_rng_state: std.Random.DefaultPrng, count: usize) !void {
            var rng_state = arg_rng_state;
            const rng = rng_state.random();

            var i: usize = 0;
            while (i < count) {
                const peeked = spin: while (true) {
                    const p = bb.peek();
                    if (p.data.len > 0) break :spin p;
                };

                const consume_count = rng.intRangeAtMost(usize, 1, peeked.data.len);
                for (peeked.data[0..consume_count], 0..) |in, j| try testing.expectEqual(@as(u8, @truncate(i + j)), in);
                peeked.consume(consume_count);

                i += consume_count;
            }
        }
    }.consumer;

    const storage = try testing.allocator.alloc(u8, bb_size);
    defer testing.allocator.free(storage);

    const seed = blk: {
        var seed: u64 = undefined;
        try std.os.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    };
    errdefer std.debug.print("bip seed: {}\n", .{seed});
    const rng_state = std.Random.DefaultPrng.init(seed);

    var bb = BB.init(storage);

    const t_cons = try std.Thread.spawn(.{}, consumer, .{ &bb, rng_state, iteration_count });
    defer t_cons.join();

    const t_prod = try std.Thread.spawn(.{}, producer, .{ &bb, rng_state, iteration_count });
    defer t_prod.join();
}
