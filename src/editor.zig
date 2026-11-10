const sj = @import("siej.zig");
const std = @import("std");
const rl = sj.rl;
const ig = @import("cimgui");
const Room = sj.room.Room;
const Data = sj.room.Data;
const Atlas = sj.graphics.Atlas;

const data_kinds = std.enums.values(Data.Kind);
const palette_size = 32; // palette button size, pixels
const preview_size = 64;
const yellow: ig.ImU32 = 0xFF00FFFF; // IM_COL32(255, 255, 0, 255), ABGR

/// What a click in the room does: paint a sprite layer, paint a data layer, or stamp a preset.
const Selection = union(enum) { sprites: usize, data: Data.Kind, preset: usize };
const presets_dir = sj.room.presets_dir;

pub const Action = enum { none, play };

pub const Editor = struct {
    sprite: u16 = 0, // selected atlas sprite
    rot: u2 = 0, // rotation to paint with, 90° clockwise steps
    sel: Selection = .{ .sprites = 0 }, // layer being painted
    layer: usize = 0, // last selected sprite layer: picking a sprite switches back to it
    tiles_dock: ig.ImGuiID = 0, // dock node of the Tiles window, where Collision opens as a tab
    presets: std.ArrayList(Room) = .empty, // small rooms in data/presets, stamped with a click
    area: ?[2][2]u16 = null, // Shift+drag selection in the room (two corner tiles), saved as a preset
    selecting: bool = false, // Shift+drag in progress
    gpa: std.mem.Allocator = undefined, // set by init; owns presets
    io: std.Io = undefined,
    value: usize = 1, // selected data value (index into the enum), picked from the palette like sprites
    show_data: bool = false, // Ctrl+D: overlay every data layer, not just the selected one
    hover: ?[2]u16 = null, // room tile under the mouse, from the last ui() call

    /// Call once after the window exists; enables docking and loads presets.
    pub fn init(self: *Editor, gpa: std.mem.Allocator, io: std.Io) void {
        self.gpa = gpa;
        self.io = io;
        rlImGuiSetup(true);
        siejImguiEnableDocking();
        siejImguiForwardMouseButtons();
        if (Room.loadAll(gpa, io, presets_dir)) |list| {
            self.presets = list;
        } else |e| std.log.err("load presets: {s}", .{@errorName(e)});
    }

    pub fn deinit(self: *Editor) void {
        rlImGuiShutdown();
        for (self.presets.items) |*p| p.deinit(self.gpa);
        self.presets.deinit(self.gpa);
    }

    /// The Shift+drag selection as top-left corner and size, in tiles.
    fn areaRect(self: Editor) ?struct { x: u16, y: u16, w: u16, h: u16 } {
        const a = self.area orelse return null;
        const x = @min(a[0][0], a[1][0]);
        const y = @min(a[0][1], a[1][1]);
        return .{ .x = x, .y = y, .w = @max(a[0][0], a[1][0]) - x + 1, .h = @max(a[0][1], a[1][1]) - y + 1 };
    }

    /// Copies the selected area of `room` into a new preset and saves it.
    fn savePreset(self: *Editor, room: Room) !void {
        const r = self.areaRect() orelse return;
        var id: u32 = 0;
        for (self.presets.items) |p| id = @max(id, p.id + 1);
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "Preset {d}", .{id});
        var preset = try room.copyRect(self.gpa, id, name, r.x, r.y, r.w, r.h);
        errdefer preset.deinit(self.gpa);
        try preset.save(self.gpa, self.io, presets_dir);
        try self.presets.append(self.gpa, preset);
        self.sel = .{ .preset = self.presets.items.len - 1 };
        self.area = null;
    }

    fn deletePreset(self: *Editor, i: usize) void {
        var p = self.presets.orderedRemove(i);
        p.deleteFile(self.io, presets_dir) catch |e| std.log.err("delete preset {d}: {s}", .{ p.id, @errorName(e) });
        p.deinit(self.gpa);
        switch (self.sel) {
            .preset => |s| if (s == i) {
                self.sel = .{ .sprites = self.layer };
            } else if (s > i) {
                self.sel = .{ .preset = s - 1 };
            },
            else => {},
        }
    }

    /// Editor-only drawing in game space (inside the render texture): data
    /// overlays and the hovered tile. Drawn under the ImGui windows.
    pub fn drawWorld(self: Editor, room: Room, atlas: Atlas) void {
        // Blend colour normally but leave the texture's alpha at 1: ImGui draws this
        // texture with alpha blending, so translucent overlays would otherwise let
        // the window background through and look dim.
        rl.gl.rlSetBlendFactorsSeparate(gl_src_alpha, gl_one_minus_src_alpha, gl_zero, gl_one, gl_func_add, gl_func_add);
        rl.beginBlendMode(.custom_separate);
        defer rl.endBlendMode();
        inline for (data_kinds) |k| {
            const selected = self.sel == .data and self.sel.data == k;
            if (self.show_data or selected) drawOverlay(room, @field(room.data, @tagName(k)), atlas);
        }
        const tw: i32 = atlas.tile_w;
        const th: i32 = atlas.tile_h;
        if (self.hover) |t| {
            if (self.sel == .preset) {
                // translucent preview of the preset where a click would stamp it
                const p = self.presets.items[self.sel.preset];
                const x: f32 = @floatFromInt(@as(i32, t[0]) * tw);
                const y: f32 = @floatFromInt(@as(i32, t[1]) * th);
                p.drawAt(atlas, 0, std.math.maxInt(usize), x, y, .{ .r = 255, .g = 255, .b = 255, .a = 160 });
                rl.drawRectangleLines(@as(i32, t[0]) * tw, @as(i32, t[1]) * th, p.w * tw, p.h * th, .yellow);
            } else {
                rl.drawRectangleLines(@as(i32, t[0]) * tw, @as(i32, t[1]) * th, tw, th, .yellow);
            }
        }
        if (self.areaRect()) |r| {
            rl.drawRectangleLinesEx(.{
                .x = @floatFromInt(@as(i32, r.x) * tw),
                .y = @floatFromInt(@as(i32, r.y) * th),
                .width = @floatFromInt(@as(i32, r.w) * tw),
                .height = @floatFromInt(@as(i32, r.h) * th),
            }, 1, .sky_blue);
        }
    }

    /// Builds the editor windows and handles painting. Call between beginDrawing and endDrawing.
    pub fn ui(self: *Editor, gpa: std.mem.Allocator, rooms: *std.ArrayList(Room), current: *usize, atlas: Atlas, view: rl.RenderTexture2D) Action {
        rlImGuiBegin();
        defer rlImGuiEnd();
        _ = ig.igDockSpaceOverViewport(0, ig.igGetMainViewport(), ig.ImGuiDockNodeFlags_PassthruCentralNode, null);

        if (!siejImguiWantTextInput()) self.shortcuts();
        const action = self.roomsWindow(gpa, rooms, current);
        self.tilesWindow(rooms.items[current.*], atlas);
        self.presetsWindow(rooms.items[current.*], atlas);
        self.collisionWindow();
        self.roomWindow(&rooms.items[current.*], atlas, view);
        return action;
    }

    fn shortcuts(self: *Editor) void {
        const ctrl = rl.isKeyDown(.left_control) or rl.isKeyDown(.right_control);
        if (ctrl and rl.isKeyPressed(.d)) self.show_data = !self.show_data;
        if (rl.isKeyPressed(.r)) self.rot +%= 1;
    }

    /// Play button, room list, the current room's sprite and data layers.
    fn roomsWindow(self: *Editor, gpa: std.mem.Allocator, rooms: *std.ArrayList(Room), current: *usize) Action {
        defer ig.igEnd();
        const sh: f32 = @floatFromInt(rl.getScreenHeight());
        ig.igSetNextWindowPos(.{ .x = 0, .y = 0 }, ig.ImGuiCond_FirstUseEver, .{});
        ig.igSetNextWindowSize(.{ .x = 180, .y = sh }, ig.ImGuiCond_FirstUseEver);
        if (!ig.igBegin("Rooms", null, 0)) return .none;

        var action: Action = .none;
        if (ig.igButton("Play (Esc stops)", .{ .x = -1, .y = 0 })) action = .play;

        var buf: [96]u8 = undefined;
        ig.igSeparatorText("Rooms");
        for (rooms.items, 0..) |r, i| {
            const label = std.fmt.bufPrintSentinel(&buf, "{d}: {s}##room{d}", .{ r.id, r.name, i }, 0) catch "?";
            if (ig.igSelectable_Bool(label, i == current.*, 0, .{})) current.* = i;
        }
        if (ig.igButton("+ room", .{})) {
            if (newRoom(gpa, rooms, rooms.items[current.*])) {
                current.* = rooms.items.len - 1;
            } else |e| std.log.err("new room: {s}", .{@errorName(e)});
        }

        const room = &rooms.items[current.*];
        ig.igSeparatorText("Layers");
        var remove: ?usize = null; // applied after the loop so indices stay valid while listing
        for (0..room.layers.items.len) |i| {
            ig.igPushID_Int(@intCast(i));
            defer ig.igPopID();
            if (ig.igSmallButton("X")) remove = i;
            ig.igSameLine(0, -1);
            const over = if (i >= sj.room.character_layer) " (over player)" else "";
            const label = std.fmt.bufPrintSentinel(&buf, "{d}: sprites{s}", .{ i, over }, 0) catch "?";
            if (ig.igSelectable_Bool(label, self.sel == .sprites and self.sel.sprites == i, 0, .{})) self.selectLayer(i);
        }
        if (remove) |i| {
            room.removeLayer(gpa, i);
            // keep the same layer; if it was the removed one, take the one below
            if (self.layer >= i and self.layer > 0) self.layer -= 1;
            if (self.sel == .sprites) self.sel = .{ .sprites = self.layer };
        }
        if (ig.igButton("+ layer", .{})) {
            if (room.addLayer(gpa)) {
                self.selectLayer(room.layers.items.len - 1);
            } else |e| std.log.err("add layer: {s}", .{@errorName(e)});
        }

        ig.igSeparatorText("Data");
        inline for (data_kinds) |k| {
            if (ig.igSelectable_Bool(@tagName(k), self.sel == .data and self.sel.data == k, 0, .{})) self.sel = .{ .data = k };
        }
        _ = ig.igCheckbox("Show all (Ctrl+D)", &self.show_data);
        return action;
    }

    fn selectLayer(self: *Editor, i: usize) void {
        self.layer = i;
        self.sel = .{ .sprites = i };
    }

    /// Sprite brush preview and palette. Picking a sprite paints the last sprite layer.
    fn tilesWindow(self: *Editor, room: Room, atlas: Atlas) void {
        defer ig.igEnd();
        const sw: f32 = @floatFromInt(rl.getScreenWidth());
        const sh: f32 = @floatFromInt(rl.getScreenHeight());
        ig.igSetNextWindowPos(.{ .x = sw - 240, .y = 0 }, ig.ImGuiCond_FirstUseEver, .{});
        ig.igSetNextWindowSize(.{ .x = 240, .y = sh }, ig.ImGuiCond_FirstUseEver);
        if (!ig.igBegin("Tiles", null, 0)) return;
        self.tiles_dock = ig.igGetWindowDockID();

        var buf: [96]u8 = undefined;
        if (self.layer >= room.layers.items.len) ig.igTextUnformatted("No sprite layer, add one.", null);
        spriteImage(atlas, self.sprite, preview_size, self.rot);
        const text = std.fmt.bufPrintSentinel(&buf, "Sprite {d}\nRot {d} (R)", .{ self.sprite, @as(u16, self.rot) * 90 }, 0) catch "";
        ig.igTextUnformatted(text, null);
        ig.igSeparatorText("Palette");
        const tex = texRef(atlas.texture);
        const aw: f32 = @floatFromInt(atlas.texture.width);
        const ah: f32 = @floatFromInt(atlas.texture.height);
        const cols = paletteCols();
        for (atlas.rects.items, 0..) |r, i| {
            paletteBegin(i, cols);
            defer paletteEnd(self.sel == .sprites and i == self.sprite);
            const uv0: ig.ImVec2_c = .{ .x = r.x / aw, .y = r.y / ah };
            const uv1: ig.ImVec2_c = .{ .x = (r.x + r.width) / aw, .y = (r.y + r.height) / ah };
            if (ig.igImageButton("##entry", tex, .{ .x = palette_size, .y = palette_size }, uv0, uv1, .{}, .{ .x = 1, .y = 1, .z = 1, .w = 1 })) {
                self.sprite = @intCast(i);
                self.sel = .{ .sprites = self.layer };
            }
        }
    }

    /// Save the Shift+drag selection as a preset; pick a preset to stamp it.
    /// Opens as a tab next to Tiles the first time.
    fn presetsWindow(self: *Editor, room: Room, atlas: Atlas) void {
        defer ig.igEnd();
        if (self.tiles_dock != 0) ig.igSetNextWindowDockID(self.tiles_dock, ig.ImGuiCond_FirstUseEver);
        if (!ig.igBegin("Presets", null, 0)) return;

        var buf: [64]u8 = undefined;
        if (self.areaRect()) |r| {
            const text = std.fmt.bufPrintSentinel(&buf, "Selected {d}x{d} tiles", .{ r.w, r.h }, 0) catch "";
            ig.igTextUnformatted(text, null);
            if (ig.igButton("Save as preset", .{})) self.savePreset(room) catch |e| std.log.err("save preset: {s}", .{@errorName(e)});
            ig.igSameLine(0, -1);
            if (ig.igButton("Clear", .{})) self.area = null;
        } else {
            ig.igTextWrapped("Shift+drag in the room to select an area, then save it here. Pick a preset and click in the room to place it.");
        }

        if (self.sel == .preset) roomImage(atlas, self.presets.items[self.sel.preset], 2 * preview_size);

        ig.igSeparatorText("Presets");
        var remove: ?usize = null; // applied after the loop so indices stay valid while listing
        for (self.presets.items, 0..) |p, i| {
            ig.igPushID_Int(@intCast(i));
            defer ig.igPopID();
            if (ig.igSmallButton("X")) remove = i;
            ig.igSameLine(0, -1);
            roomImage(atlas, p, palette_size);
            ig.igSameLine(0, -1);
            const label = std.fmt.bufPrintSentinel(&buf, "{s} ({d}x{d})", .{ p.name, p.w, p.h }, 0) catch "?";
            if (ig.igSelectable_Bool(label, self.sel == .preset and self.sel.preset == i, 0, .{})) self.sel = .{ .preset = i };
        }
        if (remove) |i| self.deletePreset(i);
    }

    /// One value palette per data layer. Picking a value paints that data layer.
    /// Opens as a tab next to Tiles the first time.
    fn collisionWindow(self: *Editor) void {
        defer ig.igEnd();
        if (self.tiles_dock != 0) ig.igSetNextWindowDockID(self.tiles_dock, ig.ImGuiCond_FirstUseEver);
        if (!ig.igBegin("Collision", null, 0)) return;

        inline for (data_kinds) |k| {
            const T = std.meta.Child(@FieldType(Data, @tagName(k)));
            const active = self.sel == .data and self.sel.data == k;
            const v = dataValue(T, self.value);
            ig.igSeparatorText(@tagName(k));
            ig.igPushID_Str(@tagName(k));
            defer ig.igPopID();
            const cols = paletteCols();
            for (std.enums.values(T), 0..) |val, i| {
                paletteBegin(i, cols);
                defer paletteEnd(active and val == v);
                if (valueButton(val, palette_size)) {
                    self.value = i;
                    self.sel = .{ .data = k };
                }
                ig.igSetItemTooltip(@tagName(val));
            }
            if (active) {
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrintSentinel(&buf, "Painting {d}: {s}", .{ @backingInt(v) + 1, @tagName(v) }, 0) catch "";
                ig.igTextUnformatted(text, null);
            }
        }
    }

    /// The game view, scaled to fit the window; painting happens here.
    fn roomWindow(self: *Editor, room: *Room, atlas: Atlas, view: rl.RenderTexture2D) void {
        defer ig.igEnd();
        const sw: f32 = @floatFromInt(rl.getScreenWidth());
        const sh: f32 = @floatFromInt(rl.getScreenHeight());
        ig.igSetNextWindowPos(.{ .x = 180, .y = 0 }, ig.ImGuiCond_FirstUseEver, .{});
        ig.igSetNextWindowSize(.{ .x = sw - 420, .y = sh }, ig.ImGuiCond_FirstUseEver);
        self.hover = null;
        if (!ig.igBegin("Room", null, ig.ImGuiWindowFlags_NoScrollbar | ig.ImGuiWindowFlags_NoScrollWithMouse)) return;

        const vw: f32 = @floatFromInt(view.texture.width);
        const vh: f32 = @floatFromInt(view.texture.height);
        const avail = ig.igGetContentRegionAvail();
        const scale = @max(0.1, @min(avail.x / vw, avail.y / vh));
        const size: ig.ImVec2_c = .{ .x = vw * scale, .y = vh * scale };
        const min = ig.igGetCursorScreenPos();
        // An invisible button owns both mouse buttons over the view; a plain image
        // would let a left click start an ImGui window drag instead of painting.
        _ = ig.igInvisibleButton("##view", size, ig.ImGuiButtonFlags_MouseButtonLeft | ig.ImGuiButtonFlags_MouseButtonRight);
        const hovered = ig.igIsItemHovered(0);
        // render textures are stored upside down: flip v
        ig.ImDrawList_AddImage(ig.igGetWindowDrawList(), texRef(view.texture), min, .{ .x = min.x + size.x, .y = min.y + size.y }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 0 }, 0xFFFFFFFF);
        if (!hovered) return;

        const m = rl.getMousePosition();
        const tx = (m.x - min.x) / scale / @as(f32, @floatFromInt(atlas.tile_w));
        const ty = (m.y - min.y) / scale / @as(f32, @floatFromInt(atlas.tile_h));
        if (tx < 0 or ty < 0 or tx >= @as(f32, @floatFromInt(room.w)) or ty >= @as(f32, @floatFromInt(room.h))) return;
        const t: [2]u16 = .{ @intFromFloat(tx), @intFromFloat(ty) };
        self.hover = t;

        const i = @as(usize, t[1]) * room.w + t[0];
        // ImGui's button state, not raylib's: raylib loses clicks shorter than a frame
        const left = ig.igIsMouseDown_Nil(ig.ImGuiMouseButton_Left);
        const right = ig.igIsMouseDown_Nil(ig.ImGuiMouseButton_Right);

        // Shift+drag selects an area (for presets) instead of painting.
        const shift = rl.isKeyDown(.left_shift) or rl.isKeyDown(.right_shift);
        if (shift and ig.igIsMouseClicked_Bool(ig.ImGuiMouseButton_Left, false)) {
            self.area = .{ t, t };
            self.selecting = true;
        }
        if (self.selecting) {
            if (left) self.area.?[1] = t else self.selecting = false;
            return;
        }
        if (shift) return;

        switch (self.sel) {
            .sprites => |l| if (l < room.layers.items.len) {
                if (left) room.layers.items[l][i] = .{ .id = self.sprite, .rot = self.rot };
                if (right) room.layers.items[l][i] = .empty;
            },
            // once per click: a held button would smear copies across the room
            .preset => |p| if (ig.igIsMouseClicked_Bool(ig.ImGuiMouseButton_Left, false)) {
                room.stamp(self.gpa, self.presets.items[p], t[0], t[1]) catch |e| std.log.err("stamp: {s}", .{@errorName(e)});
            },
            .data => |k| switch (k) {
                inline else => |kk| {
                    const cells = @field(room.data, @tagName(kk));
                    const T = std.meta.Child(@TypeOf(cells));
                    if (left) cells[i] = dataValue(T, self.value);
                    if (right) cells[i] = T.empty;
                },
            },
        }
    }
};

// OpenGL blend constants for rlSetBlendFactorsSeparate.
const gl_zero = 0;
const gl_one = 1;
const gl_src_alpha = 0x0302;
const gl_one_minus_src_alpha = 0x0303;
const gl_func_add = 0x8006;

// rlImGui (raylib backend); C linkage, see rlImGui.h.
extern fn rlImGuiSetup(dark_theme: bool) void;
extern fn rlImGuiBegin() void;
extern fn rlImGuiEnd() void;
extern fn rlImGuiShutdown() void;
// src/imgui_io.c
extern fn siejImguiEnableDocking() void;
extern fn siejImguiWantTextInput() bool;
extern fn siejImguiForwardMouseButtons() void;

fn paletteCols() usize {
    const style_pad = 8; // button frame padding + item spacing, roughly
    return @max(1, @as(usize, @intFromFloat(ig.igGetContentRegionAvail().x / (palette_size + style_pad))));
}

/// Wraps palette entry i into rows of `cols`; pair with paletteEnd.
fn paletteBegin(i: usize, cols: usize) void {
    if (i % cols != 0) ig.igSameLine(0, -1);
    ig.igPushID_Int(@intCast(i));
}

/// Outlines the entry just drawn if it is the selected brush.
fn paletteEnd(selected: bool) void {
    if (selected) ig.ImDrawList_AddRect(ig.igGetWindowDrawList(), ig.igGetItemRectMin(), ig.igGetItemRectMax(), yellow, 0, 2, 0);
    ig.igPopID();
}

/// Data value as a coloured square showing its 1-based number, like the room overlay.
fn valueButton(v: anytype, size: f32) bool {
    const p = ig.igGetCursorScreenPos();
    const clicked = ig.igColorButton("##entry", toVec4(v.color()), ig.ImGuiColorEditFlags_NoTooltip, .{ .x = size, .y = size });
    var buf: [8]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{d}", .{@backingInt(v) + 1}) catch "?";
    ig.ImDrawList_AddText_Vec2(ig.igGetWindowDrawList(), .{ .x = p.x + 4, .y = p.y + 2 }, 0xFFFFFFFF, label.ptr, label.ptr + label.len);
    return clicked;
}

/// rlImGui identifies textures by their GL id.
fn texRef(t: rl.Texture2D) ig.ImTextureRef_c {
    return .{ ._TexData = null, ._TexID = t.id };
}

fn toVec4(c: rl.Color) ig.ImVec4_c {
    return .{ .x = @as(f32, @floatFromInt(c.r)) / 255, .y = @as(f32, @floatFromInt(c.g)) / 255, .z = @as(f32, @floatFromInt(c.b)) / 255, .w = 1 };
}

/// Atlas sprite as an ImGui item, rotated rot * 90° clockwise.
fn spriteImage(atlas: Atlas, sprite: u16, size: f32, rot: u2) void {
    const p = ig.igGetCursorScreenPos();
    ig.igDummy(.{ .x = size, .y = size });
    spriteAt(atlas, sprite, p, size, size, rot);
}

/// Room scaled to fit a max*max box, as an ImGui item (preset previews).
fn roomImage(atlas: Atlas, room: Room, max: f32) void {
    const rw: f32 = @floatFromInt(@as(u32, room.w) * atlas.tile_w);
    const rh: f32 = @floatFromInt(@as(u32, room.h) * atlas.tile_h);
    const scale = max / @max(rw, rh);
    const tw = @as(f32, @floatFromInt(atlas.tile_w)) * scale;
    const th = @as(f32, @floatFromInt(atlas.tile_h)) * scale;
    const p = ig.igGetCursorScreenPos();
    ig.igDummy(.{ .x = rw * scale, .y = rh * scale });
    for (0..room.size()) |i| {
        const q: ig.ImVec2_c = .{ .x = p.x + @as(f32, @floatFromInt(i % room.w)) * tw, .y = p.y + @as(f32, @floatFromInt(i / room.w)) * th };
        for (room.layers.items) |cells| {
            if (cells[i].id) |s| spriteAt(atlas, s, q, tw, th, cells[i].rot);
        }
    }
}

fn spriteAt(atlas: Atlas, sprite: u16, p: ig.ImVec2_c, w: f32, h: f32, rot: u2) void {
    if (sprite >= atlas.rects.items.len) return;
    const r = atlas.rects.items[sprite];
    const aw: f32 = @floatFromInt(atlas.texture.width);
    const ah: f32 = @floatFromInt(atlas.texture.height);
    const left = r.x / aw;
    const top = r.y / ah;
    const right = (r.x + r.width) / aw;
    const bottom = (r.y + r.height) / ah;
    // corner uvs clockwise from top-left; rotating the image = shifting which uv lands on which corner
    const uvs = [4]ig.ImVec2_c{ .{ .x = left, .y = top }, .{ .x = right, .y = top }, .{ .x = right, .y = bottom }, .{ .x = left, .y = bottom } };
    const k: usize = 4 - @as(usize, rot);
    ig.ImDrawList_AddImageQuad(
        ig.igGetWindowDrawList(),
        texRef(atlas.texture),
        .{ .x = p.x, .y = p.y },
        .{ .x = p.x + w, .y = p.y },
        .{ .x = p.x + w, .y = p.y + h },
        .{ .x = p.x, .y = p.y + h },
        uvs[k % 4],
        uvs[(k + 1) % 4],
        uvs[(k + 2) % 4],
        uvs[(k + 3) % 4],
        0xFFFFFFFF,
    );
}

/// Data value at index i, clamped to the enum's last value.
fn dataValue(comptime T: type, i: usize) T {
    const values = std.enums.values(T);
    return values[@min(i, values.len - 1)];
}

/// Tinted cell + value number (1-based) for every cell of a data layer, in game space.
fn drawOverlay(room: Room, cells: anytype, atlas: Atlas) void {
    for (cells, 0..) |v, i| {
        const x: i32 = @intCast(i % room.w * atlas.tile_w);
        const y: i32 = @intCast(i / room.w * atlas.tile_h);
        rl.drawRectangle(x, y, atlas.tile_w, atlas.tile_h, v.color());
        var buf: [8]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{d}", .{@backingInt(v) + 1}, 0) catch "?";
        rl.drawText(label, x + 5, y + 3, 10, .{ .r = 255, .g = 255, .b = 255, .a = 200 });
    }
}

fn newRoom(gpa: std.mem.Allocator, rooms: *std.ArrayList(Room), like: Room) !void {
    var id: u32 = 0;
    for (rooms.items) |r| id = @max(id, r.id + 1);
    var room = try Room.init(gpa, id, like.w, like.h);
    errdefer room.deinit(gpa);
    try rooms.append(gpa, room);
}
