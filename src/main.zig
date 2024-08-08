const std = @import("std");
const net = std.net;

pub const io_mode = .evented;

// for an async server, basically we need a:
// TCP connection + http protocol + something to handle methods

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    // Establishing TCP
    const serverAddr = try net.Address.parseIp("127.0.0.1", 9000);
    var server = try net.Address.listen(serverAddr, .{ .reuse_address = true });

    std.log.info("Server established @ {}, listening for connections.", .{server.listen_address.in});
    std.log.debug("Server Socket {}", .{server.listen_address.any});
    std.log.debug("Server Stream {}", .{server.stream.handle});
    defer server.deinit();

    const readBuffer = try allocator.alloc(u8, 8192);
    defer allocator.free(readBuffer);
    //accept the next incomming stream connection
    while (true) {
        const clientConnection = try server.accept();
        defer clientConnection.stream.close(); // close connection after done with it
        std.log.info("Server connected to client @ {}", .{clientConnection.address.in});
        const bytesRead = try clientConnection.stream.reader().read(readBuffer);
        const line = readBuffer[0..bytesRead];
        std.log.info("packet read", .{});
        std.log.info("message from {s} : {s}", .{ "client", line });
        try clientConnection.stream.writer().print("Hello from zig server", .{});
    }

    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // don't forget to flush!
}
