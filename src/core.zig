const sj = @import("siej.zig");
const std = @import("std");
const rl = sj.rl;
const graphics = sj.graphics;
const Screen = enum {
    OVERWORLD,
    BATTLE,
};
const Window = struct {
    width: i32 = 800,
    height: i32 = 600,
    title: [:0]const u8 = "Siej", //c api
    fn init(self: *Window) void {
        rl.initWindow(self.width, self.height, self.title);
        rl.setTargetFPS(60);
    }
    fn deinit(_: *Window) void {
        rl.closeWindow();
    }
    fn shouldClose(_: *Window) bool {
        return rl.windowShouldClose();
    }
};

pub const Core = struct {
    window: Window,
    allocator: std.heap.DebugAllocator(.{}) = .init,
    arena: std.heap.ArenaAllocator = undefined,
    drawing: bool = false,
    render_w: i32 = 240,
    render_h: i32 = 160,
    render_texture: rl.RenderTexture2D = undefined,
    current_screen: Screen = .OVERWORLD,
    atlas: graphics.Atlas = undefined,
    rooms: std.ArrayList(sj.room.Room) = .empty,
    current_room: usize = 0,
    editor: sj.editor.Editor = .{},
    playing: bool = false,
    player: sj.character.Player = .{},
    player_tex: rl.Texture2D = undefined,
    io: std.Io = undefined,
    pub fn init(self: *Core) !void {
        self.arena = .init(self.allocator.allocator());
        rl.setConfigFlags(.{ .window_resizable = true, .vsync_hint = true });
        self.window.init();
        rl.setWindowMinSize(self.render_w, self.render_h);
        rl.setExitKey(.home);
        self.render_texture = try rl.loadRenderTexture(self.render_w, self.render_h);
        rl.setTextureFilter(self.render_texture.texture, .point); // crisp pixels when scaled up
        self.editor.init(self.allocator.allocator(), self.io);
    }
    pub fn deinit(self: *Core) void {
        self.editor.deinit(); // GL resources: before closeWindow
        rl.unloadRenderTexture(self.render_texture); // before closeWindow: needs the GL context
        self.window.deinit();
        self.arena.deinit();
        _ = self.allocator.deinit();
    }
    pub fn run(self: *Core) !void {
        const gpa = self.allocator.allocator();
        self.atlas = try graphics.Atlas.load(gpa, "assets/tileset.png", 16, 16);
        defer self.atlas.deinit(gpa);
        self.player_tex = try rl.loadTexture("assets/char.png");
        defer rl.unloadTexture(self.player_tex);
        defer {
            for (self.rooms.items) |*r| r.deinit(gpa);
            self.rooms.deinit(gpa);
        }

        self.rooms = try sj.room.Room.loadAll(gpa, self.io, sj.room.rooms_dir);
        if (self.rooms.items.len == 0) {
            try self.rooms.append(gpa, try sj.room.Room.init(gpa, 0, 15, 10));
        }

        while (!self.window.shouldClose()) {
            update(self);
        }
    }
    pub fn update(self: *Core) void {
        const room = &self.rooms.items[self.current_room];
        if (self.playing) {
            if (rl.isKeyPressed(.escape)) self.playing = false;
            self.player.update(room.*, rl.getFrameTime());
            draw(self);
            return;
        }
        const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        if (ctrl and rl.isKeyPressed(.s)) {
            const r = &self.rooms.items[self.current_room]; // the editor may have switched or added rooms
            r.save(self.allocator.allocator(), self.io, sj.room.rooms_dir) catch |e| std.log.err("save room {d}: {s}", .{ r.id, @errorName(e) });
        }
        draw(self);
    }
    /// Game texture letterboxed into the whole window (play mode).
    fn viewport(self: *Core) rl.Rectangle {
        const sw: f32 = @floatFromInt(rl.getScreenWidth());
        const sh: f32 = @floatFromInt(rl.getScreenHeight());
        const rw: f32 = @floatFromInt(self.render_w);
        const rh: f32 = @floatFromInt(self.render_h);
        const scale = @min(sw / rw, sh / rh);
        return .{ .x = (sw - rw * scale) * 0.5, .y = (sh - rh * scale) * 0.5, .width = rw * scale, .height = rh * scale };
    }
    pub fn draw(self: *Core) void {
        self.drawing = true;
        rl.beginTextureMode(self.render_texture);
        rl.clearBackground(.ray_white);
        switch (self.current_screen) {
            .OVERWORLD => {
                const room = self.rooms.items[self.current_room];
                const split = sj.room.character_layer;
                room.draw(self.atlas, 0, split);
                if (self.playing) self.player.draw(self.player_tex, self.atlas.tile_w, self.atlas.tile_h);
                room.draw(self.atlas, split, std.math.maxInt(usize));
                if (!self.playing) self.editor.drawWorld(room, self.atlas);
            },
            .BATTLE => {
                //drawBatte
            },
        }
        rl.endTextureMode();
        rl.beginDrawing();
        rl.clearBackground(.black);
        if (self.playing) {
            const rw: f32 = @floatFromInt(self.render_w);
            const rh: f32 = @floatFromInt(self.render_h);
            rl.drawTexturePro(self.render_texture.texture, .{ .x = 0, .y = 0, .width = rw, .height = -rh }, self.viewport(), .{ .x = 0, .y = 0 }, 0.0, .white);
        } else if (self.editor.ui(self.allocator.allocator(), &self.rooms, &self.current_room, self.atlas, self.render_texture) == .play) {
            self.playing = true;
            self.player = .spawn(self.rooms.items[self.current_room]);
        }
        rl.endDrawing();
        self.drawing = false;
    }
};

var instance: Core = .{ .window = .{} };
pub fn get() *Core {
    return &instance;
}
