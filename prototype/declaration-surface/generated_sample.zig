//! GENERATED from the domain declaration by gen.zig. Do not edit.

pub const Author = struct {
    id: i64,
    email: []const u8,
    name: []const u8,

    pub const table = "authors";
    pub const create_table_sql = "create table authors (id bigint not null generated always as identity primary key, email text not null, name text not null)";

    /// has_many posts (stub)
    pub fn posts(self: Author) []const Post {
        _ = self;
        return &.{};
    }

    pub const RegisterInput = struct {
        email: []const u8,
        name: []const u8,
    };
    /// POST  /authors/register {email, name} (stub: returns its route)
    pub fn register(input: RegisterInput) []const u8 {
        _ = input;
        return "POST  /authors/register {email, name}";
    }

    pub const ByEmailInput = struct {
        email: []const u8,
    };
    /// GET   /authors/by_email {email} (stub: returns its route)
    pub fn by_email(input: ByEmailInput) []const u8 {
        _ = input;
        return "GET   /authors/by_email {email}";
    }
};

pub const Post = struct {
    id: i64,
    author_id: i64,
    title: []const u8,
    body: ?[]const u8,
    published: bool,

    pub const table = "posts";
    pub const create_table_sql = "create table posts (id bigint not null generated always as identity primary key, author_id bigint not null references authors, title text not null, body text, published boolean not null)";

    /// belongs_to author (stub)
    pub fn author(self: Post) ?Author {
        _ = self;
        return null;
    }

    pub const DraftInput = struct {
        author_id: i64,
        title: []const u8,
        body: ?[]const u8,
    };
    /// POST  /posts/draft {author_id, title, body} (stub: returns its route)
    pub fn draft(input: DraftInput) []const u8 {
        _ = input;
        return "POST  /posts/draft {author_id, title, body}";
    }

    pub const PublishInput = struct {
        published: bool,
    };
    /// PATCH /posts/publish {published} (stub: returns its route)
    pub fn publish(input: PublishInput) []const u8 {
        _ = input;
        return "PATCH /posts/publish {published}";
    }

    pub const ByAuthorInput = struct {
        author_id: i64,
    };
    /// GET   /posts/by_author {author_id} (stub: returns its route)
    pub fn by_author(input: ByAuthorInput) []const u8 {
        _ = input;
        return "GET   /posts/by_author {author_id}";
    }
};
