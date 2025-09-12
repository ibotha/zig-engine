const std = @import("std");
const vk = @import("vulkan");
const core = @import("core");

const mem = std.mem;
const Allocator = mem.Allocator;

const Allocation = struct {
    size: usize,
    alignment: mem.Alignment,
    scope: vk.SystemAllocationScope,
};

const VkAllocator = struct {
    allocator: Allocator = undefined,
    allocations: std.AutoHashMap(?*anyopaque, Allocation) = undefined,
    callbacks: vk.AllocationCallbacks = .{
        .p_user_data = null,
        .pfn_allocation = allocate,
        .pfn_free = free,
        .pfn_reallocation = reallocate,
    },
    alloc_count: usize = 0,
    realloc_count: usize = 0,
    free_count: usize = 0,
    total_size: usize = 0,
};

var state = VkAllocator{};

pub const callbacks = &state.callbacks;

pub fn init() !void {
    state.allocator = core.tagged_allocator(.graphics_context);
    state.allocations = .init(state.allocator);
}

pub fn deinit() void {
    state.allocations.clearAndFree();
}

fn allocate(_: ?*anyopaque, size: usize, raw_alignment: usize, scope: vk.SystemAllocationScope) callconv(.c) ?*anyopaque {
    const alignment = mem.Alignment.fromByteUnits(raw_alignment);
    const ret = state.allocator.rawAlloc(size, alignment, @returnAddress());

    state.allocations.put(ret, .{
        .size = size,
        .alignment = alignment,
        .scope = scope,
    }) catch |err| switch (err) {
        error.OutOfMemory => {
            std.debug.print("Out of memory while allocating {d} bytes\n", .{size});
            return null;
        },
    };
    state.alloc_count += 1;
    state.total_size += size;
    return @ptrCast(ret);
}

fn reallocate(p_user_data: ?*anyopaque, ptr: ?*anyopaque, size: usize, raw_alignment: usize, scope: vk.SystemAllocationScope) callconv(.c) ?*anyopaque {
    const allocation = state.allocations.get(ptr) orelse {
        return null;
    };

    const ret = allocate(p_user_data, size, raw_alignment, scope);
    const copy_len = @min(size, allocation.size);
    const cast_ptr: [*c]u8 = @ptrCast(ptr);
    const cast_ret: [*c]u8 = @ptrCast(ret);
    @memcpy(cast_ret[0..copy_len], cast_ptr[0..copy_len]);
    free(p_user_data, ptr);
    state.realloc_count += 1;
    state.alloc_count -= 1;
    state.free_count -= 1;
    return @ptrCast(ret);
}

fn free(_: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    const allocation = state.allocations.get(ptr) orelse {
        std.debug.print("Freeing unknown ptr {any} in VkAllocator\n", .{ptr});
        return;
    };
    const cast_ptr: [*c]u8 = @ptrCast(ptr);
    state.allocator.rawFree(cast_ptr[0..allocation.size], allocation.alignment, @returnAddress());
    _ = state.allocations.remove(ptr);
    state.free_count += 1;
    state.total_size -= allocation.size;
}

pub fn reset_counts() void {
    state.alloc_count = 0;
    state.realloc_count = 0;
    state.free_count = 0;
}

pub fn report() void {
    var it = state.allocations.keyIterator();
    var total_mem: usize = 0;
    var total_allocs: usize = 0;
    while (it.next()) |k| {
        const allocation = state.allocations.get(k.*).?;
        total_mem += allocation.size;
        total_allocs += 1;
    }
    std.debug.print("{} allocations.\n", .{state.alloc_count});
    std.debug.print("{} reallocations.\n", .{state.realloc_count});
    std.debug.print("{} frees.\n", .{state.free_count});
    std.debug.print("Total memory usage: {} bytes over {} allocations\n", .{ total_mem, total_allocs });
}
