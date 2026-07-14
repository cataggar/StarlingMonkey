extern fn engine_add(a: i32, b: i32) i32;
export fn @"shell-call"(a: i32, b: i32) i32 {
    return engine_add(a, b);
}
