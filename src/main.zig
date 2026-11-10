const sj = @import("siej.zig");
pub fn main(init: @import("std").process.Init) !void {
    var core = sj.core.get();
    core.io = init.io;
    core.window.height = 600;
    core.window.width = 800;
    core.window.title = "Test";
    try core.init();
    defer core.deinit();
    try core.run();
}
