const sj = @import("siej.zig");
const rl = sj.rl;
const Room = sj.room.Room;

const Character = struct {
    name: []const u8,
};

/// Grid-locked player: walks one tile per step, only onto walkable tiles,
/// sliding smoothly between tiles.
pub const Player = struct {
    x: u16 = 0, // tile it stands on, or is walking into
    y: u16 = 0,
    from_x: u16 = 0, // tile it is walking from
    from_y: u16 = 0,
    t: f32 = 1, // progress of the current step, 0..1; 1 = standing

    const step_time = 0.15; // ponytail: tuning knob for walk speed, seconds per tile

    /// On the first walkable tile, or (0, 0) if there is none.
    pub fn spawn(room: Room) Player {
        for (room.data.collision, 0..) |c, i| {
            if (c == .walkable) {
                const x: u16 = @intCast(i % room.w);
                const y: u16 = @intCast(i / room.w);
                return .{ .x = x, .y = y, .from_x = x, .from_y = y };
            }
        }
        return .{};
    }

    /// Finishes the current step, then starts the next one if a direction is
    /// held. Leftover time carries over so holding a key walks without stutter.
    pub fn update(self: *Player, room: Room, dt: f32) void {
        if (self.t < 1) {
            self.t += dt / step_time;
            if (self.t < 1) return;
        }
        const leftover = self.t - 1;
        self.t = 1;
        self.from_x = self.x;
        self.from_y = self.y;

        const dx: i32, const dy: i32 = if (held(.up, .w)) .{ 0, -1 } else if (held(.down, .s)) .{ 0, 1 } else if (held(.left, .a)) .{ -1, 0 } else if (held(.right, .d)) .{ 1, 0 } else return;
        const nx = @as(i32, self.x) + dx;
        const ny = @as(i32, self.y) + dy;
        if (nx < 0 or ny < 0 or nx >= room.w or ny >= room.h) return;
        const i = @as(usize, @intCast(ny)) * room.w + @as(usize, @intCast(nx));
        if (room.data.collision[i] != .walkable) return;
        self.x = @intCast(nx);
        self.y = @intCast(ny);
        self.t = @min(leftover, 0.99);
    }

    /// In game (render texture) space, interpolated between from and the target tile.
    /// The sprite's bottom sits on the tile, so a tall sprite overlaps the tile above.
    pub fn draw(self: Player, tex: rl.Texture2D, tile_w: u16, tile_h: u16) void {
        const tw: f32 = @floatFromInt(tile_w);
        const th: f32 = @floatFromInt(tile_h);
        const x = lerp(self.from_x, self.x, self.t) * tw;
        const y = lerp(self.from_y, self.y, self.t) * th;
        const sh: f32 = @floatFromInt(tex.height);
        rl.drawTextureV(tex, .{ .x = @round(x), .y = @round(y + th - sh) }, .white);
    }
};

fn lerp(a: u16, b: u16, t: f32) f32 {
    const fa: f32 = @floatFromInt(a);
    const fb: f32 = @floatFromInt(b);
    return fa + (fb - fa) * t;
}

fn held(a: rl.KeyboardKey, b: rl.KeyboardKey) bool {
    return rl.isKeyDown(a) or rl.isKeyDown(b);
}
