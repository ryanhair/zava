const zava = @import("zava");
const api = @import("api");

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const res_name = "Author";
    pub const table = "authors";
    pub const actions: []const zava.Action(Author) = &.{
        .{ .name = "register", .accept = &.{ .email, .name }, .after = .welcome },
        .{ .name = "rename", .accept = &.{.name} },
    };

    /// Hook: typed on a generated type, body calls the generated API.
    pub fn welcome(self: *Author, input: api.Author.RegisterInput) void {
        self.* = api.Author.rename(self.*, .{ .name = "Welcome" });
        _ = input.email;
    }
};
pub const resources = .{Author};
