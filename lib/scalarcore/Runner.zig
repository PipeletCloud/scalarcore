const std = @import("std");
const builtin = @import("builtin");
const closure = @import("closure");
const xev = @import("xev");
const Allocator = std.mem.Allocator;
const ThreadPool = if (builtin.single_threaded) void else xev.ThreadPool;
const Task = if (builtin.single_threaded) void else xev.ThreadPool.Task;
const Core = @import("Core.zig");
const Job = @import("Job.zig");
const LoadBalancer = @import("LoadBalancer.zig");
const Self = @This();

pub const Options = @import("Runner/Options.zig");

pub const State = enum {
    waiting,
    running,
    failed,
    done,
};

core_id: std.atomic.Value(usize),
job_id: std.atomic.Value(usize),
max_jobs: usize,
use_affinity: bool,
cores: []?*Core,
thread_pool: ThreadPool,
atomic_state: std.atomic.Value(u32),
monitor_task: Task,
load_balancer: ?*LoadBalancer,

pub fn create(alloc: Allocator, options: Options) !*Self {
    const cores = try alloc.alloc(?*Core, try options.maxCores());
    errdefer alloc.free(cores);

    @memset(cores, null);

    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    self.* = .{
        .core_id = .init(0),
        .job_id = .init(0),
        .max_jobs = try options.maxJobs(),
        .use_affinity = options.useAffinity(),
        .cores = cores,
        .thread_pool = if (ThreadPool != void) .init(.{
            .max_threads = @intCast(cores.len),
        }) else {},
        .atomic_state = .init(@intFromEnum(State.waiting)),
        .monitor_task = if (Task != void) .{ .callback = monitorCallback } else {},
        .load_balancer = null,
    };
    return self;
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    if (ThreadPool != void) {
        self.thread_pool.shutdown();
        self.thread_pool.deinit();
    }

    for (self.cores) |*opt_core| {
        if (opt_core.*) |core| core.deinit(alloc);
    }

    alloc.free(self.cores);
    alloc.destroy(self);
}

fn monitorCallback(task: *Task) void {
    const self: *Self = @fieldParentPtr("monitor_task", task);
    while (true) {
        if (self.state() != .running) return;

        var complete_count: usize = 0;
        var sched_count: usize = 0;
        var failed_count: usize = 0;

        for (self.cores) |*opt_core| {
            if (opt_core.*) |core| {
                const stats = core.stats();
                if (stats.isComplete()) {
                    if (stats.failed_jobs > 0) failed_count += 1;
                    complete_count += 1;
                }
                sched_count += 1;
            }
        }

        if (sched_count == complete_count) {
            if (failed_count == 0) {
                self.atomic_state.store(@intFromEnum(State.failed), .monotonic);
            } else {
                self.atomic_state.store(@intFromEnum(State.done), .monotonic);
            }
        }
    }
}

fn getCore(self: *Self, alloc: Allocator, i: usize) !struct { *Core, bool } {
    const will_alloc = self.cores[i] == null;
    if (will_alloc) {
        const id = self.core_id.fetchAdd(1, .monotonic);
        self.cores[i] = try .create(id, &self.job_id, alloc, self.max_jobs, self.use_affinity);
        if (self.state() == .running and ThreadPool != void) {
            var batch: ThreadPool.Batch = .{};
            batch.push(.from(&self.cores[i].?.task));
            self.thread_pool.schedule(batch);
        }
    }
    return .{ self.cores[i].?, will_alloc };
}

pub fn findAvailableCore(self: *Self, alloc: Allocator) !?struct { *Core, bool } {
    for (self.cores) |*opt_core| {
        if (opt_core.*) |core| {
            if (core.findFreeJob() != null) return .{ core, false };
        }
    }

    for (self.cores, 0..) |*core, i| {
        if (core.* == null) {
            return try self.getCore(alloc, i);
        }
    }
    return null;
}

pub fn findAvailableCoreFor(self: *Self, alloc: Allocator, func: *const Job.WorkerFunc, userdata: ?*anyopaque) !?struct { *Core, bool } {
    if (self.load_balancer) |lb| {
        const loc = lb.shouldPlace(self, func, userdata);
        return switch (loc) {
            .core => |i| try self.getCore(alloc, i),
            .job => try self.findAvailableCore(alloc),
        };
    }
    return self.findAvailableCore(alloc);
}

pub fn state(self: *Self) State {
    return @enumFromInt(self.atomic_state.load(.monotonic));
}

pub fn wait(self: *Self, timeout: ?u64) error{Timeout}!void {
    if (timeout) |t| {
        try std.Thread.Futex.timedWait(&self.atomic_state, @intFromEnum(State.running), t);
    } else {
        std.Thread.Futex.wait(&self.atomic_state, @intFromEnum(State.running));
    }
}

pub fn pushJob(self: *Self, alloc: Allocator, func: *const Job.WorkerFunc, userdata: ?*anyopaque) !*?Job {
    if (try self.findAvailableCoreFor(alloc, func, userdata)) |result| {
        const core, const did_alloc = result;

        const job = try core.pushJob(func, userdata);
        if (self.load_balancer) |lb| {
            try lb.markPlacement(func, userdata, core.id, job.*.?.id, if (did_alloc) .core else .job);
            job.*.?.load_balancer = .{
                .lb = lb,
                .core_id = core.id,
            };
        }
        return job;
    }
    // TODO: push this to a queue
    return error.OutOfCores;
}

pub fn runAsync(self: *Self) !void {
    if (ThreadPool != void) {
        var batch: ThreadPool.Batch = .{};
        batch.push(.from(&self.monitor_task));

        for (self.cores) |*opt_core| {
            if (opt_core.*) |core| {
                batch.push(.from(&core.task));
            }
        }

        self.atomic_state.store(@intFromEnum(State.running), .monotonic);
        self.thread_pool.schedule(batch);
    } else {
        self.atomic_state.store(@intFromEnum(State.running), .monotonic);

        for (self.cores) |*opt_core| {
            if (opt_core.*) |core| {
                core.run() catch |err| {
                    self.atomic_state.store(@intFromEnum(State.failed), .monotonic);
                    return err;
                };
            }
        }

        self.atomic_state.store(@intFromEnum(State.done), .monotonic);
    }
}

pub fn runSync(self: *Self, timeout: ?u64) !void {
    try self.runAsync();
    if (ThreadPool != void) try self.wait(timeout);
}

fn testWorker(userdata: ?*anyopaque) anyerror!void {
    const bool_ptr: *bool = @ptrCast(@alignCast(userdata.?));
    bool_ptr.* = true;
}

fn testError(_: ?*anyopaque) anyerror!void {
    return error.Unexpected;
}

test {
    std.testing.refAllDecls(@This());
}

test "Sync" {
    const alloc = std.testing.allocator;

    const runner = try create(alloc, .{
        .max_jobs = if (builtin.single_threaded) 2 else null,
    });
    defer runner.deinit(alloc);

    var did_run: bool = false;
    _ = try runner.pushJob(alloc, testWorker, &did_run);

    var did_run2: bool = false;
    _ = try runner.pushJob(alloc, testWorker, &did_run2);

    try runner.runSync(null);

    try std.testing.expectEqual(true, did_run);
    try std.testing.expectEqual(true, did_run2);
}
