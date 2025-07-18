const std = @import("std");
const Allocator = std.mem.Allocator;
const Job = @import("Job.zig");
const Runner = @import("Runner.zig");
const Self = @This();

pub const Placement = enum {
    core,
    job,
};

pub const PlacementLocation = union(Placement) {
    core: usize,
    job: void,
};

pub const VTable = struct {
    shouldPlace: *const fn (?*anyopaque, *Runner, *const Job.WorkerFunc, ?*anyopaque) PlacementLocation,
    markPlacement: *const fn (?*anyopaque, *const Job.WorkerFunc, ?*anyopaque, usize, usize, Placement) anyerror!void,
    unmarkPlacement: *const fn (?*anyopaque, usize, usize) anyerror!void,
    deinit: ?*const fn (?*anyopaque, Allocator) void = null,
};

vtable: *const VTable,
ptr: ?*anyopaque,

pub fn shouldPlace(self: *Self, runner: *Runner, func: *const Job.WorkerFunc, userdata: ?*anyopaque) PlacementLocation {
    return self.vtable.shouldPlace(self.ptr, runner, func, userdata);
}

pub fn markPlacement(self: *Self, func: *const Job.WorkerFunc, userdata: ?*anyopaque, core_id: usize, job_id: usize, method: Placement) anyerror!void {
    return self.vtable.markPlacement(self.ptr, func, userdata, core_id, job_id, method);
}

pub fn unmarkPlacement(self: *Self, core_id: usize, job_id: usize) anyerror!void {
    return self.vtable.unmarkPlacement(self.ptr, core_id, job_id);
}

pub fn deinit(self: *Self, alloc: Allocator) void {
    if (self.vtable.deinit) |f| f(self.ptr, alloc);
}
