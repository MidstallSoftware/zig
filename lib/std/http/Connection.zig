const std = @import("../std.zig");

pub const buffer_size = std.crypto.tls.max_ciphertext_record_len;
const BufferSize = std.math.IntFittingRange(0, buffer_size);

/// The plaintext stream this connection is using.
stream: std.net.Stream,
