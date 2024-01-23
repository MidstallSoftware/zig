export fn a() usize {
    _ = @expect(10, 1, 1.2);
}

export fn b() usize {
    _ = @expect(10, 1, -1.2);
}

// error
// backend=stage2
// target=native
//
// :3:23: error: @expect probability must be between 0.0 and 1.0 inclusively, found 1.2
// :6:24: error: @expect probability must be between 0.0 and 1.0 inclusively, found -1.2
