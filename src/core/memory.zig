const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
var base_allocator: Allocator = gpa.allocator();

const AllocationTag = enum(u8) {
    events = 0,
    graphics_context = 1,
};

const TaggedAllocator = struct {
    tag: AllocationTag,
    allocated_bytes: u64 = 0,
};

var allocators: [@typeInfo(AllocationTag).@"enum".fields.len]TaggedAllocator = undefined;

pub fn init() void {
    for (0..@typeInfo(AllocationTag).@"enum".fields.len) |l| {
        allocators[l] = .{
            .tag = @enumFromInt(l),
        };
    }
}

pub fn deinit() void {
    if (gpa.deinit() == .leak) {
        @panic("Leak detected in engine");
    }
}

pub fn report() void {
    std.log.debug("Allocation report", .{});
    var total: u64 = 0;
    for (allocators) |a| {
        const readout = mem_size_readout(a.allocated_bytes);
        std.log.debug("    [{s}]: {d} {s}", .{ @tagName(a.tag), readout.size, readout.unit });
        total += a.allocated_bytes;
    }
    const readout = mem_size_readout(total);
    std.log.debug("Total: {d} {s}", .{ readout.size, readout.unit });
}

fn mem_size_readout(size: u64) struct { size: u64, unit: []const u8 } {
    const kib = 1024;
    const mib = kib * 1024;
    const gib = mib * 1024;
    return if (size < kib)
        .{ .size = size, .unit = "B" }
    else if (size < mib)
        .{ .size = size / kib, .unit = "KiB" }
    else if (size < gib)
        .{ .size = size / mib, .unit = "MiB" }
    else
        .{ .size = size / gib, .unit = "GiB" };
}

fn alloc(data: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    var a: *TaggedAllocator = @ptrCast(@alignCast(data));
    a.allocated_bytes += len;
    return base_allocator.rawAlloc(len, alignment, ret_addr);
}
fn resize(data: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    var a: *TaggedAllocator = @ptrCast(@alignCast(data));
    a.allocated_bytes += new_len - memory.len;
    return base_allocator.rawResize(memory, alignment, new_len, ret_addr);
}

fn remap(data: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    var a: *TaggedAllocator = @ptrCast(@alignCast(data));
    a.allocated_bytes += new_len - memory.len;
    return base_allocator.rawRemap(memory, alignment, new_len, ret_addr);
}

fn free(data: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
    var a: *TaggedAllocator = @ptrCast(@alignCast(data));
    a.allocated_bytes -= memory.len;
    return base_allocator.rawFree(memory, alignment, ret_addr);
}

pub fn tagged_allocator(tag: AllocationTag) Allocator {
    return .{
        .ptr = @ptrCast(&allocators[@intFromEnum(tag)]),
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}
