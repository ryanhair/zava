const std = @import("std");
const zava = @import("zava");
pub fn main(init: std.process.Init) !void {
    return zava.runCommand(init);
}
