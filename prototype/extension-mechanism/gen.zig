const std = @import("std");
const zava = @import("zava");
pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var fw = std.Io.File.stdout().writer(init.io, &buf);
    try zava.emit(&fw.interface);
    try fw.interface.flush();
}
