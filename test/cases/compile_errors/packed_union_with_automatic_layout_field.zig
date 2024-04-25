const Foo = struct {
    a: u32,
    b: f32,
};
const Payload = packed union(u64) {
    A: Foo,
    B: u64,
};
export fn entry() void {
    const a: Payload = .{ .B = 10 };
    _ = a;
}

// error
// backend=stage2
// target=native
//
// :6:8: error: packed unions cannot contain fields of type 'tmp.Foo'
// :6:8: note: only packed structs layout are allowed in packed types
// :1:13: note: struct declared here
