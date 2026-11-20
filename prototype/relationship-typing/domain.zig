const zava = @import("zava");
const m: u8 = @import("cfg").mistake;

pub const Author = struct {
    id: i64,
    name: []const u8,
    // No relationships declaration at all: fine.
    pub const resource = zava.Options(@This()){ .primary_key = .id };
};

pub const Comment = struct {
    id: i64,
    post_id: i64,
    flagged: bool,

    pub const relationships: []const zava.Relationship(@This()) = &.{
        .{ .name = "post", .kind = .belongs_to, .destination = Post, .source_attribute = if (m == 6) .post else .post_id },
    };
    pub const resource = zava.Options(@This()){
        .primary_key = .id,
        .actions = &.{.{
            .name = "on_popular",
            // to-one, then back across a to-many of the far side
            .filter = .through(.post, .exists(.comments, .eq(.flagged, .value(true)))),
        }},
    };
};

pub const Post = struct {
    id: i64,
    author_id: i64,
    views: i64,

    pub const relationships: []const zava.Relationship(@This()) = if (m == 7) &.{} else &.{
        .{ .name = "comments", .kind = .has_many, .destination = Comment },
        .{ .name = "author", .kind = .belongs_to, .destination = Author, .source_attribute = .author_id },
    };
    const hidden = 1;

    pub const resource = zava.Options(@This()){
        .primary_key = .id,
        .actions = &.{.{
            .name = "discussed",
            .load = &.{if (m == 5) .coments else .comments},
            .filter = switch (m) {
                0, 5, 6, 7, 8 => .all(&.{
                    .exists(.comments, .eq(.flagged, .value(true))),
                    .through(.author, .eq(.name, .value("ada"))),
                }),
                1 => .exists(.coments, .eq(.flagged, .value(true))), // misspelled relationship
                2 => .exists(.comments, .eq(.flaged, .value(true))), // misspelled far-side attribute
                3 => .exists(.comments, .eq(.flagged, .value(1))), // far-side literal of the wrong type
                4 => .exists(.author, .eq(.name, .value("ada"))), // existence test over a to-one
                else => unreachable,
            },
        }},
    };
};

/// Misspelled declaration name: caught by the near-miss check.
pub const Tag = struct {
    id: i64,
    pub const relationship: []const zava.Relationship(@This()) = &.{};
    pub const resource = zava.Options(@This()){ .primary_key = .id };
};
pub const touch = if (m == 8) Tag.resource.primary_key else {};
