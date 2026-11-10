const sj = @import("siej.zig");
const std = @import("std");
const rl = sj.rl;
const Atlas = sj.graphics.Atlas;

pub const rooms_dir = "data/rooms";
/// Presets are small rooms: a captured arrangement of tiles, stamped into rooms.
pub const presets_dir = "data/presets";
pub const character_layer = 3;
pub const Sprite = struct {
    id: ?u16 = null,
    rot: u2 = 0,
    pub const empty: Sprite = .{};
};

/// Shown as 1, 2, 3 in the editor overlay.
pub const Collision = enum {
    walkable,
    solid,
    water,
    pub const empty: Collision = .walkable;
    pub fn color(self: Collision) rl.Color {
        return switch (self) {
            .walkable => .{ .r = 0, .g = 200, .b = 0, .a = 70 },
            .solid => .{ .r = 220, .g = 0, .b = 0, .a = 110 },
            .water => .{ .r = 0, .g = 90, .b = 255, .a = 110 },
        };
    }
};

pub const Data = struct {
    collision: []Collision = &.{},

    pub const Kind = std.meta.FieldEnum(Data);

    fn init(gpa: std.mem.Allocator, n: usize) !Data {
        var d: Data = .{};
        errdefer d.deinit(gpa);
        inline for (comptime std.meta.fieldNames(Data)) |name| @field(d, name) = try filled(std.meta.Child(@FieldType(Data, name)), gpa, n);
        return d;
    }

    fn deinit(self: Data, gpa: std.mem.Allocator) void {
        inline for (comptime std.meta.fieldNames(Data)) |name| gpa.free(@field(self, name));
    }

    /// Copy of loaded data: missing fields get filled with `empty`, wrong sizes are rejected.
    fn dupe(self: Data, gpa: std.mem.Allocator, n: usize) !Data {
        var d: Data = .{};
        errdefer d.deinit(gpa);
        inline for (comptime std.meta.fieldNames(Data)) |name| {
            const T = std.meta.Child(@FieldType(Data, name));
            const src = @field(self, name);
            @field(d, name) = if (src.len == 0)
                try filled(T, gpa, n)
            else if (src.len == n)
                try gpa.dupe(T, src)
            else
                return error.InvalidRoom;
        }
        return d;
    }
};

fn filled(comptime T: type, gpa: std.mem.Allocator, n: usize) ![]T {
    const cells = try gpa.alloc(T, n);
    @memset(cells, T.empty);
    return cells;
}

pub const Room = struct {
    id: u32,
    name: []const u8,
    w: u16,
    h: u16,
    layers: std.ArrayList([]Sprite), // sprite layers, drawn bottom to top
    data: Data,

    /// On-disk shape: same fields, layers as a plain slice.
    const File = struct { id: u32, name: []const u8, w: u16, h: u16, layers: []const []Sprite, data: Data };

    /// One sprite layer plus all data layers. Owned by gpa; free with deinit.
    pub fn init(gpa: std.mem.Allocator, id: u32, w: u16, h: u16) !Room {
        var room: Room = .{ .id = id, .name = try gpa.dupe(u8, "Default Room"), .w = w, .h = h, .layers = .empty, .data = .{} };
        errdefer room.deinit(gpa);
        room.data = try Data.init(gpa, room.size());
        try room.addLayer(gpa);
        return room;
    }

    pub fn deinit(self: *Room, gpa: std.mem.Allocator) void {
        for (self.layers.items) |l| gpa.free(l);
        self.layers.deinit(gpa);
        self.data.deinit(gpa);
        gpa.free(self.name);
    }

    pub fn size(self: Room) usize {
        return @as(usize, self.w) * self.h;
    }

    /// Appends an empty sprite layer on top.
    pub fn addLayer(self: *Room, gpa: std.mem.Allocator) !void {
        const layer = try filled(Sprite, gpa, self.size());
        errdefer gpa.free(layer);
        try self.layers.append(gpa, layer);
    }

    /// Removes sprite layer i; the layers above it move down one.
    pub fn removeLayer(self: *Room, gpa: std.mem.Allocator, i: usize) void {
        gpa.free(self.layers.orderedRemove(i));
    }

    /// Reads a room saved by `save`.
    pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, file: []const u8) !Room {
        const json = try dir.readFileAlloc(io, file, gpa, .limited(16 << 20));
        defer gpa.free(json);
        const parsed = try std.json.parseFromSlice(File, gpa, json, .{});
        defer parsed.deinit();
        const f = parsed.value;

        var room: Room = .{ .id = f.id, .name = try gpa.dupe(u8, f.name), .w = f.w, .h = f.h, .layers = .empty, .data = .{} };
        errdefer room.deinit(gpa);
        for (f.layers) |l| if (l.len != room.size()) return error.InvalidRoom;
        room.data = try f.data.dupe(gpa, room.size());
        try room.layers.ensureTotalCapacity(gpa, f.layers.len);
        for (f.layers) |l| room.layers.appendAssumeCapacity(try gpa.dupe(Sprite, l));
        return room;
    }

    /// Every <dir>/*.json, sorted by id. Unreadable files are logged and skipped.
    pub fn loadAll(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !std.ArrayList(Room) {
        var rooms: std.ArrayList(Room) = .empty;
        errdefer {
            for (rooms.items) |*r| r.deinit(gpa);
            rooms.deinit(gpa);
        }
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound => return rooms,
            else => return e,
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            const room = load(gpa, io, dir, entry.name) catch |e| {
                std.log.err("load room {s}: {s}", .{ entry.name, @errorName(e) });
                continue;
            };
            try rooms.append(gpa, room);
        }
        std.mem.sort(Room, rooms.items, {}, struct {
            fn lt(_: void, a: Room, b: Room) bool {
                return a.id < b.id;
            }
        }.lt);
        return rooms;
    }

    /// Writes the room to <dir>/<id>.json.
    pub fn save(self: Room, gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, dir_path);
        const f: File = .{ .id = self.id, .name = self.name, .w = self.w, .h = self.h, .layers = self.layers.items, .data = self.data };
        const json = try std.json.Stringify.valueAlloc(gpa, f, .{});
        defer gpa.free(json);
        var buf: [256]u8 = undefined;
        try cwd.writeFile(io, .{ .sub_path = try self.path(&buf, dir_path), .data = json });
    }

    /// Deletes <dir>/<id>.json.
    pub fn deleteFile(self: Room, io: std.Io, dir_path: []const u8) !void {
        var buf: [256]u8 = undefined;
        try std.Io.Dir.cwd().deleteFile(io, try self.path(&buf, dir_path));
    }

    fn path(self: Room, buf: []u8, dir_path: []const u8) ![]u8 {
        return std.fmt.bufPrint(buf, "{s}/{d}.json", .{ dir_path, self.id });
    }

    /// A new w*h room holding a copy of this room's area at (x, y): every
    /// sprite layer and data layer, cell positions kept. The area must fit.
    pub fn copyRect(self: Room, gpa: std.mem.Allocator, id: u32, name: []const u8, x: u16, y: u16, w: u16, h: u16) !Room {
        var out: Room = .{ .id = id, .name = try gpa.dupe(u8, name), .w = w, .h = h, .layers = .empty, .data = .{} };
        errdefer out.deinit(gpa);
        out.data = try Data.init(gpa, out.size());
        for (self.layers.items) |_| try out.addLayer(gpa);
        for (0..h) |dy| {
            for (0..w) |dx| {
                const src = (y + dy) * self.w + x + dx;
                const dst = dy * w + dx;
                for (self.layers.items, out.layers.items) |s, d| d[dst] = s[src];
                inline for (comptime std.meta.fieldNames(Data)) |n| @field(out.data, n)[dst] = @field(self.data, n)[src];
            }
        }
        return out;
    }

    /// Pastes `src` with its top-left on (x, y). Layer k goes onto layer k (layers
    /// are added if src has more). Empty cells are transparent: they keep what is
    /// underneath, so a building keeps the ground around it. Parts outside are dropped.
    pub fn stamp(self: *Room, gpa: std.mem.Allocator, src: Room, x: u16, y: u16) !void {
        while (self.layers.items.len < src.layers.items.len) try self.addLayer(gpa);
        for (0..src.h) |dy| {
            for (0..src.w) |dx| {
                const tx = x + dx;
                const ty = y + dy;
                if (tx >= self.w or ty >= self.h) continue;
                const s = dy * src.w + dx;
                const d = ty * self.w + tx;
                for (src.layers.items, 0..) |cells, k| {
                    if (cells[s].id != null) self.layers.items[k][d] = cells[s];
                }
                inline for (comptime std.meta.fieldNames(Data)) |n| {
                    const v = @field(src.data, n)[s];
                    if (v != @TypeOf(v).empty) @field(self.data, n)[d] = v;
                }
            }
        }
    }

    /// Sprite layers [from, to), clamped to what the room has; tile by tile, each
    /// tile bottom to top. Splitting into ranges gives the same picture as one
    /// pass, since a sprite never covers neighbouring tiles.
    pub fn draw(self: Room, atlas: Atlas, from: usize, to: usize) void {
        self.drawAt(atlas, from, to, 0, 0, .white);
    }

    /// Like draw, offset by (x0, y0) pixels and tinted (the editor's preset preview).
    pub fn drawAt(self: Room, atlas: Atlas, from: usize, to: usize, x0: f32, y0: f32, tint: rl.Color) void {
        const layers = self.layers.items[@min(from, self.layers.items.len)..@min(to, self.layers.items.len)];
        const tw: f32 = @floatFromInt(atlas.tile_w);
        const th: f32 = @floatFromInt(atlas.tile_h);
        for (0..self.size()) |i| {
            const dst: rl.Rectangle = .{
                .x = x0 + @as(f32, @floatFromInt(i % self.w)) * tw,
                .y = y0 + @as(f32, @floatFromInt(i / self.w)) * th,
                .width = tw,
                .height = th,
            };
            for (layers) |cells| {
                if (cells[i].id) |s| atlas.draw(s, dst, cells[i].rot, tint);
            }
        }
    }
};
