const sj = @import("siej.zig");
const rl = sj.rl;
const std = @import("std");

/// One texture on the GPU; a sprite is an index into `rects` (non-empty cells only).
pub const Atlas = struct {
    texture: rl.Texture2D,
    rects: std.ArrayList(rl.Rectangle),
    tile_w: u16,
    tile_h: u16,

    pub fn load(gpa: std.mem.Allocator, path: [:0]const u8, tile_w: u16, tile_h: u16) !Atlas {
        if (tile_w == 0 or tile_h == 0) return error.InvalidTileSize;
        const img = try rl.loadImage(path);
        defer rl.unloadImage(img);
        const pixels = try rl.loadImageColors(img);
        defer rl.unloadImageColors(pixels);

        const img_w: usize = @intCast(img.width);
        const cols = img_w / tile_w;
        const rows = @as(usize, @intCast(img.height)) / tile_h;
        var rects = try std.ArrayList(rl.Rectangle).initCapacity(gpa, cols * rows);
        errdefer rects.deinit(gpa);
        for (0..rows) |r| {
            for (0..cols) |c| {
                const x = c * tile_w;
                const y = r * tile_h;
                if (isEmpty(pixels, img_w, x, y, tile_w, tile_h)) continue;
                rects.appendAssumeCapacity(.{
                    .x = @floatFromInt(x),
                    .y = @floatFromInt(y),
                    .width = @floatFromInt(tile_w),
                    .height = @floatFromInt(tile_h),
                });
            }
        }
        return .{ .texture = try rl.loadTextureFromImage(img), .rects = rects, .tile_w = tile_w, .tile_h = tile_h };
    }

    pub fn deinit(self: *Atlas, gpa: std.mem.Allocator) void {
        rl.unloadTexture(self.texture);
        self.rects.deinit(gpa);
    }

    /// Draws sprite stretched into dst, rotated rot * 90° clockwise around dst's center.
    pub fn draw(self: Atlas, sprite: u16, dst: rl.Rectangle, rot: u2, tint: rl.Color) void {
        if (sprite >= self.rects.items.len) return; // stale index from a room saved with another atlas
        const half: rl.Vector2 = .{ .x = dst.width / 2, .y = dst.height / 2 };
        const centered: rl.Rectangle = .{ .x = dst.x + half.x, .y = dst.y + half.y, .width = dst.width, .height = dst.height };
        rl.drawTexturePro(self.texture, self.rects.items[sprite], centered, half, @as(f32, @floatFromInt(rot)) * 90, tint);
    }
};

/// True if every pixel of the w*h cell at (x0, y0) is fully transparent.
fn isEmpty(pixels: []const rl.Color, stride: usize, x0: usize, y0: usize, w: usize, h: usize) bool {
    for (y0..y0 + h) |y| {
        for (pixels[y * stride + x0 ..][0..w]) |p| if (p.a != 0) return false;
    }
    return true;
}
