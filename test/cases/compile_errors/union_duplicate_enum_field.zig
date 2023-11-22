const E = enum { a, b };
const U = union(E) {
    a: u32,
    a: u32,
};

export fn foo() void {
    var u: U = .{ .a = 123 };
    _ = u;
}

// error
// target=native
//
// :3:5: error: duplicate union field: 'a'
// :4:5: note: other field here
// :2:11: note: union declared here
