const std = @import("std");
const builtin = @import("builtin");
const closure = @import("closure");
const xev = @import("xev");
const Allocator = std.mem.Allocator;
const native_os = builtin.os.tag;
const Task = if (builtin.single_threaded) void else xev.ThreadPool.Task;
const ThreadId = if (builtin.single_threaded) void else ?std.Thread.Id;
const Job = @import("Job.zig");
const Self = @This();

pub const State = enum {
    running,
    waiting,
    failed,
    done,
};

pub const Stats = struct {
    max_jobs: usize,
    sched_jobs: usize,
    running_jobs: usize,
    failed_jobs: usize,
    done_jobs: usize,
    idle_jobs: usize,
    waiting_jobs: usize,

    pub fn completeCount(self: *const Stats) usize {
        return self.failed_jobs + self.done_jobs;
    }

    pub fn isComplete(self: *const Stats) bool {
        return self.completeCount() == self.sched_jobs;
    }
};

id: usize,
tid: ThreadId,
job_id: *std.atomic.Value(usize),
task: Task,
loop: xev.Loop,
jobs: []?Job,
atomic_state: std.atomic.Value(u32),
set_affinity: bool,

pub fn create(id: usize, job_id: *std.atomic.Value(usize), alloc: Allocator, max_jobs: usize, set_affinity: bool) !*Self {
    const jobs = try alloc.alloc(?Job, max_jobs);
    errdefer alloc.free(jobs);

    @memset(jobs, null);

    var loop = try xev.Loop.init(.{});
    errdefer loop.deinit();

    const self = try alloc.create(Self);
    errdefer alloc.destroy(self);

    self.* = .{
        .id = id,
        .tid = if (ThreadId != void) std.Thread.getCurrentId() else {},
        .job_id = job_id,
        .task = if (Task != void) .{
            .callback = taskCallback,
        } else {},
        .loop = loop,
        .jobs = jobs,
        .atomic_state = .init(@intFromEnum(State.waiting)),
        .set_affinity = set_affinity,
    };
    return self;
}

pub fn setAffinity(self: *Self) !void {
    if (ThreadId != void) {
        if (native_os == .linux) {
            var cpu_set = std.mem.zeroes(std.posix.cpu_set_t);

            const core = self.id % try std.Thread.getCpuCount();

            const i = core >> std.math.log2(@sizeOf(usize));
            cpu_set[i] |= @as(usize, 1) << @as(u6, @truncate((core & (@sizeOf(usize) - 1))));

            try std.os.linux.sched_setaffinity(@bitCast(self.tid orelse unreachable), &cpu_set);
            return;
        }
    }
    return error.Unsupported;
}

pub fn run(self: *Self) !void {
    self.atomic_state.store(@intFromEnum(State.running), .monotonic);

    for (self.jobs) |opt_job| {
        if (opt_job) |job| {
            job.x_async.notify() catch {
                self.atomic_state.store(@intFromEnum(State.failed), .monotonic);
                return;
            };
        }
    }

    self.loop.run(.until_done) catch |err| {
        self.atomic_state.store(@intFromEnum(State.failed), .monotonic);
        return err;
    };

    for (self.jobs) |*opt_job| {
        if (opt_job.*) |*job| {
            if (job.state() == .failed) {
                self.atomic_state.store(@intFromEnum(State.failed), .monotonic);

                if (job.err) |err| {
                    return err.throw();
                }
                return;
            }
        }
    }

    self.atomic_state.store(@intFromEnum(State.done), .monotonic);
}

pub fn wait(self: *Self, timeout: ?u64) error{Timeout}!void {
    if (timeout) |t| {
        try std.Thread.Futex.timedWait(&self.atomic_state, @intFromEnum(State.running), t);
    } else {
        std.Thread.Futex.wait(&self.atomic_state, @intFromEnum(State.running));
    }
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    for (self.jobs) |*opt_job| {
        if (opt_job.*) |*job| job.deinit(alloc);
    }

    alloc.free(self.jobs);
    self.loop.deinit();

    alloc.destroy(self);
}

pub fn findFreeJob(self: *Self) ?*?Job {
    for (self.jobs) |*opt_job| {
        if (opt_job.* == null) return opt_job;
        if (opt_job.*) |*job| {
            if (job.state() == .done) {
                return opt_job;
            }
        }
    }
    return null;
}

pub fn pushJob(self: *Self, func: *const Job.WorkerFunc, userdata: ?*anyopaque) !*?Job {
    if (self.findFreeJob()) |opt_job| {
        const id = self.job_id.fetchAdd(1, .monotonic);
        if (opt_job.* == null) {
            try Job.init(opt_job, id, func, userdata);
        } else {
            Job.reset(&opt_job.*.?, id, func, userdata);
        }

        Job.queue(&opt_job.*.?, &self.loop);
        return opt_job;
    }
    return error.OutOfJobs;
}

pub fn state(self: *Self) State {
    return @enumFromInt(self.atomic_state.load(.monotonic));
}

pub fn stats(self: *Self) Stats {
    var value: Stats = .{
        .max_jobs = self.jobs.len,
        .sched_jobs = 0,
        .running_jobs = 0,
        .failed_jobs = 0,
        .done_jobs = 0,
        .idle_jobs = 0,
        .waiting_jobs = 0,
    };

    for (self.jobs) |*opt_job| {
        if (opt_job.*) |*job| {
            value.sched_jobs += 1;
            switch (job.state()) {
                .waiting => value.waiting_jobs += 1,
                .running => value.running_jobs += 1,
                .failed => value.failed_jobs += 1,
                .done => value.done_jobs += 1,
            }
        } else {
            value.idle_jobs += 1;
        }
    }

    return value;
}

fn taskCallback(task: *Task) void {
    const self: *Self = @fieldParentPtr("task", task);
    self.tid = if (ThreadId != void) std.Thread.getCurrentId() else {};

    if (self.set_affinity) {
        self.setAffinity() catch unreachable;
    }

    self.run() catch unreachable;
}

test {
    std.testing.refAllDecls(@This());
}

fn testWorker(userdata: ?*anyopaque) anyerror!bool {
    const bool_ptr: *bool = @ptrCast(@alignCast(userdata.?));
    bool_ptr.* = true;
    return false;
}

fn testError(_: ?*anyopaque) anyerror!bool {
    return error.Unexpected;
}

test "Standalone usage" {
    const alloc = std.testing.allocator;

    var job_id = std.atomic.Value(usize).init(0);

    const core = try create(0, &job_id, alloc, 2, false);
    defer core.deinit(alloc);

    try std.testing.expectEqual(&core.jobs[0], core.findFreeJob());

    var did_run: bool = false;
    _ = try core.pushJob(testWorker, &did_run);

    try std.testing.expectEqual(&core.jobs[1], core.findFreeJob());

    var did_run2: bool = false;
    _ = try core.pushJob(testWorker, &did_run2);

    try std.testing.expectEqual(@as(?*?Job, null), core.findFreeJob());

    try core.run();
    try core.wait(null);

    try std.testing.expectEqual(true, did_run);
    try std.testing.expectEqual(true, did_run2);
}

test "Error handling" {
    const alloc = std.testing.allocator;

    var job_id = std.atomic.Value(usize).init(0);

    const core = try create(0, &job_id, alloc, 1, false);
    defer core.deinit(alloc);

    try std.testing.expectEqual(&core.jobs[0], core.findFreeJob());

    _ = try core.pushJob(testError, null);

    try std.testing.expectError(error.Unexpected, core.run());
    try core.wait(null);
}
