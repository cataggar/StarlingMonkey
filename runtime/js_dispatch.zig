const std = @import("std");

const DispatchResult = extern struct {
    ptr: ?[*]u8,
    len: usize,
};

extern fn starling_js_dispatch(
    export_name_ptr: [*]const u8,
    export_name_len: usize,
    args_json_ptr: [*]const u8,
    args_json_len: usize,
    result: *DispatchResult,
) u32;

extern fn free(ptr: ?*anyopaque) void;

var result_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);

pub fn call(comptime export_name: []const u8, comptime Result: type, args: anytype) Result {
    var args_json: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer args_json.deinit();
    std.json.Stringify.value(args, .{}, &args_json.writer) catch
        @panic("failed to serialize JavaScript arguments");

    var dispatch_result: DispatchResult = .{ .ptr = null, .len = 0 };
    if (starling_js_dispatch(
        export_name.ptr,
        export_name.len,
        args_json.written().ptr,
        args_json.written().len,
        &dispatch_result,
    ) != 0) {
        @panic("JavaScript export dispatch failed");
    }

    if (Result == void) {
        free(if (dispatch_result.ptr) |ptr| @ptrCast(ptr) else null);
        return;
    }

    const result_ptr = dispatch_result.ptr orelse
        @panic("JavaScript export dispatch returned no result");
    defer free(@ptrCast(result_ptr));
    _ = result_arena.reset(.retain_capacity);
    return std.json.parseFromSliceLeaky(
        Result,
        result_arena.allocator(),
        result_ptr[0..dispatch_result.len],
        .{},
    ) catch @panic("failed to decode the JavaScript return value");
}

test "serializes lifted arguments as a JSON array" {
    const Point = struct { x: i32, label: []const u8 };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.json.Stringify.value(.{ @as(u32, 7), Point{ .x = -2, .label = "a" } }, .{}, &output.writer);
    try std.testing.expectEqualStrings("[7,{\"x\":-2,\"label\":\"a\"}]", output.written());
}

test "decodes structured JavaScript results" {
    const Result = struct { greeting: []const u8, values: []const u32, extra: ?bool };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try std.json.parseFromSliceLeaky(
        Result,
        arena.allocator(),
        "{\"greeting\":\"hello\",\"values\":[1,2],\"extra\":null}",
        .{},
    );
    try std.testing.expectEqualStrings("hello", result.greeting);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, result.values);
    try std.testing.expectEqual(null, result.extra);
}
