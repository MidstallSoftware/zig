const std = @import("../std.zig");
const websocket = std.websocket;

const mem = std.mem;
const base64 = std.base64;

const Uri = std.Uri;
const Sha1 = std.crypto.hash.Sha1;

const Client = @This();

key: [handshake_key_length_b64]u8,
prng: std.rand.DefaultPrng,
http: std.http.Client,

const websocket_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const handshake_key_length = 16;
const handshake_key_length_b64 = base64.standard.Encoder.calcSize(handshake_key_length);
const encoded_key_length_b64 = base64.standard.Encoder.calcSize(Sha1.digest_length);

fn checkHandshakeKey(original: []const u8, received: []const u8) bool {
    var hash = Sha1.init(.{});
    hash.update(original);
    hash.update(websocket_guid);

    var hashed_key: [Sha1.digest_length]u8 = undefined;
    hash.final(&hashed_key);

    var encoded: [encoded_key_length_b64]u8 = undefined;
    _ = base64.standard.Encoder.encode(&encoded, &hashed_key);

    return mem.eql(u8, &encoded, received);
}

pub const Response = struct {
    conn: *Connection,
    frame: websocket.Frame,
    read_left: u64,

    pub fn read(msg: *Response, buf: []u8) !usize {
        if (msg.read_left == 0) return 0;

        const needed = @min(buf.len, @truncate(usize, msg.read_left));
        const filled = msg.conn.node.data.buffered.read(buf[0..needed]);
        msg.read_left -= filled;

        return filled;
    }
};

pub const Connection = struct {
    node: *std.http.Client.ConnectionPool.Node,
    client: *Client,

    pub fn next(conn: *Connection) !Response {
        const reader = conn.node.data.buffered.reader();

        var message = Response{
            .conn = conn,
            .frame = undefined,
        };

        const first = try reader.readByte();
        message.frame.fin = first & 0x80 == 0x80;
        message.frame.rsv1 = first & 0x40 == 0x40;
        message.frame.rsv2 = first & 0x20 == 0x20;
        message.frame.rsv3 = first & 0x10 == 0x10;
        message.frame.opcode = @intToEnum(websocket.Opcode, @truncate(u4, first));

        const second = try reader.readByte();
        const masked = second & 0x80 == 0x80;
        const len0 = @truncate(u7, second);

        switch (len0) {
            127 => message.frame.length = try reader.readIntBig(u64),
            126 => message.frame.length = try reader.readIntBig(u16),
            else => message.frame.length = len0,
        }

        if (masked) {
            // message.frame.mask = try reader.readIntNative(u32);
            // server frames are not allowed to have a mask

            return error.InvalidFrame;
        } else {
            message.frame.mask = null;
        }

        message.left = message.frame.length;

        return message;
    }

    pub fn writeAll(conn: *Connection, opcode: websocket.Opcode, fin: bool, data: []const u8) !usize {
        var buffered = std.io.bufferedWriter(conn.node.data.buffered.writer());
        const writer = buffered.writer();

        var frame: [14]u8 = undefined;

        frame[0] = @enumToInt(opcode);
        if (fin) frame[0] |= 0x80;

        const mask = conn.client.prng.random().int(u32);

        frame[1] = 0x80;
        if (data.len > std.math.maxInt(u16)) {
            frame[1] |= 127;
            std.mem.writeIntBig(u64, frame[2..10], data.len);
            std.mem.writeIntNative(u32, frame[10..14], mask);

            try writer.writeAll(frame[0..14]);
        } else if (data.len >= 126) {
            frame[1] |= 126;
            std.mem.writeIntBig(u16, frame[2..4], @truncate(u16, data.len));
            std.mem.writeIntNative(u32, frame[4..8], mask);

            try writer.writeAll(frame[0..8]);
        } else {
            frame[1] |= @truncate(u8, data.len);
            std.mem.writeIntNative(u32, frame[2..6], mask);

            try writer.writeAll(frame[0..6]);
        }

        const aligned_len = std.mem.alignBackward(data.len, 4);
        const slice = mem.bytesAsSlice(u32, data.len[0..aligned_len]);

        for (slice) |c| {
            try writer.writeIntNative(u32, c ^ mask);
        }

        const mask_bytes = mem.asBytes(mask);
        switch (data.len - aligned_len) {
            0 => {},
            1 => {
                try writer.writeByte(data[aligned_len] ^ mask_bytes[0]);
            },
            2 => {
                try writer.writeByte(data[aligned_len] ^ mask_bytes[0]);
                try writer.writeByte(data[aligned_len + 1] ^ mask_bytes[1]);
            },
            3 => {
                try writer.writeByte(data[aligned_len] ^ mask_bytes[0]);
                try writer.writeByte(data[aligned_len + 1] ^ mask_bytes[1]);
                try writer.writeByte(data[aligned_len + 2] ^ mask_bytes[2]);
            },
            else => unreachable,
        }

        buffered.flush();

        return data.len;
    }
};

pub fn init(allocator: std.mem.Allocator) Client {
    const seed = @bitCast(u64, std.time.microTimestamp());
    var prng = std.rand.DefaultPrng.init(seed);

    var raw_key: [handshake_key_length]u8 = undefined;
    prng.random().bytes(&raw_key);

    var client = Client{
        .http = std.http.Client{ .allocator = allocator },
        .prng = prng,
        .key = undefined,
    };

    base64.standard.Encoder.encode(&client.key, &raw_key);

    return client;
}

pub fn handshake(client: *Client, uri: Uri, headers: std.http.Headers) !Connection {
    if (headers.contains("sec-websocket-key")) return error.InvalidHeader;
    if (headers.contains("sec-websocket-version")) return error.InvalidHeader;
    if (headers.contains("connection")) return error.InvalidHeader;
    if (headers.contains("upgrade")) return error.InvalidHeader;

    try headers.append("connection", "upgrade");
    try headers.append("upgrade", "websocket");
    try headers.append("sec-websocket-version", "13");
    try headers.append("sec-websocket-key", &client.key);

    const req = try client.http.request(uri, headers, .{
        .method = .GET,
    });

    try req.do();

    if (req.response.status != .switching_protocols) return error.HandshakeFailed;

    const connection = req.response.headers.getFirstValue("connection");
    const accept = req.response.headers.getFirstValue("sec-websocket-accept");

    if (connection == null or accept == null) return error.HandshakeFailed;
    if (!std.ascii.eqlIgnoreCase(connection.?, "upgrade")) return error.HandshakeFailed;
    if (checkHandshakeKey(&client.key, accept.?)) return error.HandshakeFailed;

    return Connection{
        .client = client,
        .node = req.connection,
    };
}
