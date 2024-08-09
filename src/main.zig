const std = @import("std");
const net = std.net;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.server);

const LF: u8 = 0xA;
const CR: u8 = 0xD;
const SP: u8 = 0x20;
const CRLF = [2]u8{ CR, LF };

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

    log.info("Server established @ {}, listening for connections.\n", .{server.listen_address.in});
    defer server.deinit();

    //accept the next incomming stream connection
    while (true) {
        const clientConnection = try server.accept();
        log.info("== New Server Connection Accepted ==", .{});
        log.info("Server connected to client @ {}", .{clientConnection.address.in});
        const request = try parseHTTPMessage(allocator, clientConnection.stream);
        defer request.deinit();
        // defer request.headers.*.deinit();
        log.info("== Http Request Detected! ==", .{});
        log.info("Method=\"{s}\" Uri=\"{s}\" Version=\"{s}\"", .{ request.method, request.uri, request.version });
        // const bodyStream = stream;
        log.info("Headers=", .{});
        var headersIter = request.headers.iterator();
        while (headersIter.next()) |header| {
            log.info("\t{s}: {s}", .{ header.key_ptr.*, header.value_ptr.* });
        }
        log.info("== End of Request ==\n", .{});
        defer clientConnection.stream.close(); // close connection after done with it
        // defer allocator.free(request);
        try clientConnection.stream.writer().print("Hello from zig server", .{});
    }

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    try stdout.print("Closing Server", .{});
    try bw.flush(); // don't forget to flush!
}

const HttpRequest = struct {
    const Self = @This();
    method: []const u8,
    uri: []const u8,
    version: []const u8,
    headers: std.StringHashMap([]const u8),
    bodyStream: net.Stream.Reader,
    allocator: Allocator,
    pub fn deinit(request: Self) void {
        _ = request;
        // request.allocator.free(request.method);
        // request.allocator.free(request.uri);
        // request.allocator.free(request.version);
        // request.allocator.free(request.headers);
    }
};

fn parseHTTPMessage(allocator: Allocator, stream: net.Stream) !HttpRequest {
    log.info("Parsing data stream from client...", .{});
    // An HTTP/1.1 message consists of a start-line followed by a CRLF
    // In the interest of robustness, a server that is expecting to receive and parse a request-line SHOULD ignore at least one empty line (CRLF) received prior to the request-line. (TODO)
    var bytesRead = try stream.reader().readUntilDelimiterAlloc(allocator, LF, 8192);

    // handles is CR is precedes LF or not. Note the range indexing is non inclusive.
    const startLine = if (bytesRead[bytesRead.len - 1] == CR) bytesRead[0 .. bytesRead.len - 1] else bytesRead;

    // A request-line begins with a method token, followed by a single space (SP), the request-target, and another single space (SP), and ends with the protocol version
    var parseIter = std.mem.splitSequence(u8, startLine, &[_]u8{SP});
    const method = parseIter.next().?;
    const uri = parseIter.next().?;
    const version = parseIter.next().?;

    // Note: the server SHOULD respond with a 400 (Bad Request) response and close the connection if the request is not in the correct shape.
    var headersMap = std.StringHashMap([]const u8).init(allocator);
    getHeaders: while (true) {
        // every header split by a CRLF
        bytesRead = try stream.reader().readUntilDelimiterAlloc(allocator, LF, 8192);
        const firstChar = bytesRead[0];
        if (firstChar == SP) {
            if (headersMap.count() == 0) {
                // A recipient that receives whitespace between the start-line and the first header field;
                // either reject the message as invalid OR ignore lines until a properly formed header field is received or the header section is terminated.
                return error.HttpInvalidMessage;
            }
            // non initial header lines starting with single spaces are continuation of last (TODO)
            return error.HttpInvalidMessage;
        }
        // a line with only CRLF indicates the end of the headers. Note `LF` is already truncated by `readUntilDelimiter`
        if (firstChar == CR and bytesRead.len == 1) {
            break;
        }
        // truncate CR (if it exists) on header line
        const headerLine = if (bytesRead[bytesRead.len - 1] == CR) bytesRead[0 .. bytesRead.len - 1] else bytesRead;
        // shape of headers is `HEADER_NAME ':' SP HEADER_VALUE` (SP is optional)
        parseIter = std.mem.splitSequence(u8, headerLine, ":");
        const key = parseIter.next().?;
        var value = parseIter.next() orelse "";
        // truncate the inital SP before storing.
        value = if (value[0] == SP and value.len > 1) value[1..] else value;
        std.debug.assert(!(std.mem.eql(u8, value, &[_]u8{SP})));
        // log.info("inserting header - {d}:{d}", .{ key, value });
        try headersMap.put(key, value);
        continue :getHeaders;
    }
    const request = HttpRequest{ .headers = headersMap, .bodyStream = stream.reader(), .method = method, .uri = uri, .version = version, .allocator = allocator };
    return request;
}
