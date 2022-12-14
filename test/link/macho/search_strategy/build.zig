const std = @import("std");
const Builder = std.build.Builder;
const LibExeObjectStep = std.build.LibExeObjStep;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target: std.zig.CrossTarget = .{ .os_tag = .macos };

    const test_step = b.step("test", "Test");
    test_step.dependOn(b.getInstallStep());

    {
        // -search_dylibs_first
        const exe = createScenario(b, mode, target);
        exe.search_strategy = .dylibs_first;

        const check_exe = exe.checkObject(.macho, .{});
        const check = check_exe.root();
        check.match("cmd LOAD_DYLIB");
        check.match("name @rpath/liba.dylib");

        const run = check_exe.runAndCompare();
        run.cwd = b.pathFromRoot(".");
        run.expectStdOutEqual("Hello world");
        test_step.dependOn(&run.step);
    }

    {
        // -search_paths_first
        const exe = createScenario(b, mode, target);
        exe.search_strategy = .paths_first;

        const run = std.build.EmulatableRunStep.create(b, "run", exe);
        run.cwd = b.pathFromRoot(".");
        run.expectStdOutEqual("Hello world");
        test_step.dependOn(&run.step);
    }
}

fn createScenario(b: *Builder, mode: std.builtin.Mode, target: std.zig.CrossTarget) *LibExeObjectStep {
    const static = b.addStaticLibrary("a", null);
    static.setTarget(target);
    static.setBuildMode(mode);
    static.addCSourceFile("a.c", &.{});
    static.linkLibC();
    static.override_dest_dir = std.build.InstallDir{
        .custom = "static",
    };
    static.install();

    const dylib = b.addSharedLibrary("a", null, b.version(1, 0, 0));
    dylib.setTarget(target);
    dylib.setBuildMode(mode);
    dylib.addCSourceFile("a.c", &.{});
    dylib.linkLibC();
    dylib.override_dest_dir = std.build.InstallDir{
        .custom = "dynamic",
    };
    dylib.install();

    const exe = b.addExecutable("main", null);
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addCSourceFile("main.c", &.{});
    exe.linkSystemLibraryName("a");
    exe.linkLibC();
    exe.addLibraryPath(b.pathFromRoot("zig-out/static"));
    exe.addLibraryPath(b.pathFromRoot("zig-out/dynamic"));
    exe.addRPath(b.pathFromRoot("zig-out/dynamic"));
    return exe;
}
