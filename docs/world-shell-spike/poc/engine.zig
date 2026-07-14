const std = @import("std");
var counter: i32 = 100;
export fn engine_add(a: i32, b: i32) i32 {
    counter += 1;
    return a + b + counter;
}
export fn engine_counter() i32 {
    return counter;
}
