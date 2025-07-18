const std = @import("std");
const xev = @import("xev");
const closure = @import("closure");
const Allocator = std.mem.Allocator;
const Self = @This();

pub const Error = struct {
    id: std.meta.Int(.unsigned, @bitSizeOf(anyerror)),
    name: []const u8,
    trace: ?std.builtin.StackTrace,

    pub fn init(err: anyerror, trace: ?*std.builtin.StackTrace) Error {
        return .{
            .id = @intFromError(err),
            .name = @errorName(err),
            .trace = if (trace) |t| t.* else null,
        };
    }

    pub fn throw(self: *const Error) anyerror!void {
        if (@errorReturnTrace()) |t| {
            if (self.trace) |trace| t.* = trace;
        }
        return @errorFromInt(self.id);
    }
};

pub const State = enum {
    running,
    waiting,
    failed,
    done,
};

pub const WorkerFunc = fn (?*anyopaque) anyerror!void;

id: usize,
x_async: xev.Async,
completion: xev.Completion,
worker: closure.ImplClosure(WorkerFunc),
atomic_state: std.atomic.Value(u32),
err: ?Error,

pub fn init(self: *?Self, id: usize, func: *const WorkerFunc, userdata: ?*anyopaque) !void {
    const x_async = try xev.Async.init();
    errdefer x_async.deinit();

    self.* = .{
        .id = id,
        .x_async = x_async,
        .completion = undefined,
        .worker = .{
            .args = .{userdata},
            .func = func,
        },
        .atomic_state = .init(@intFromEnum(State.waiting)),
        .err = null,
    };
}

pub fn reset(self: *Self, id: usize, func: *const WorkerFunc, userdata: ?*anyopaque) void {
    self.id = id;
    self.worker = .{
        .args = .{userdata},
        .func = func,
    };
    self.atomic_state.store(@intFromEnum(State.waiting), .monotonic);
}

pub fn queue(self: *Self, loop: *xev.Loop) void {
    self.atomic_state.store(@intFromEnum(State.running), .monotonic);
    self.x_async.wait(loop, &self.completion, Self, self, waitCallback);
}

pub fn deinit(self: *Self, _: Allocator) void {
    self.x_async.deinit();
}

pub fn wait(self: *Self, timeout: ?u64) error{Timeout}!void {
    if (timeout) |t| {
        return std.Thread.Futex.timedWait(&self.atomic_state, @intFromEnum(State.running), t);
    } else {
        std.Thread.Futex.wait(&self.atomic_state, @intFromEnum(State.running));
    }
}

pub fn state(self: *Self) State {
    return @enumFromInt(self.atomic_state.load(.monotonic));
}

fn waitCallback(self_: ?*Self, _: *xev.Loop, _: *xev.Completion, r: xev.Async.WaitError!void) xev.CallbackAction {
    const self = self_ orelse unreachable;
    _ = r catch |err| {
        self.err = .init(err, @errorReturnTrace());
        self.atomic_state.store(@intFromEnum(State.failed), .monotonic);
        return .rearm;
    };

    self.err = null;
    self.worker.run() catch |err| {
        self.err = .init(err, @errorReturnTrace());
        self.atomic_state.store(@intFromEnum(State.failed), .monotonic);
        return .disarm;
    };

    self.atomic_state.store(@intFromEnum(State.done), .monotonic);
    return .disarm;
}

test {
    std.testing.refAllDecls(@This());
}
