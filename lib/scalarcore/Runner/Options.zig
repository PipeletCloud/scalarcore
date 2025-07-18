const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;
const Self = @This();

max_jobs: ?usize = null,
max_cores: ?usize = null,
use_affinity: ?bool = null,

fn getCpuCount() !usize {
    if (builtin.single_threaded) return 1;
    return std.Thread.getCpuCount();
}

pub fn maxCores(self: *const Self) !usize {
    if (self.max_cores) |max_cores| return max_cores;
    return getCpuCount();
}

pub fn maxJobs(self: *const Self) !usize {
    if (self.max_jobs) |max_jobs| return max_jobs;
    return getCpuCount();
}

pub fn useAffinity(self: *const Self) bool {
    return self.use_affinity orelse switch (native_os) {
        .linux => true,
        else => false,
    };
}

test {
    std.testing.refAllDecls(@This());
}
