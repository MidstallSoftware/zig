comptime {
    var a: bool = undefined;
    _ = &a;
    _ = a or a;
}

// error
// backend=stage2
// target=native
//
// :4:9: error: use of undefined value here causes undefined behavior
