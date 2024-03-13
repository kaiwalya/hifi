const std = @import("std");

const proc = @import("./processor.zig");
const two_pi: proc.SignalSlice = @splat(2.0 * std.math.pi);
pub const SweepInit = struct {
    allocator: std.mem.Allocator,
    time: f32,
    min_f: f32,
    max_f: f32,

    //1.0, linear gradiant, 0.1, initially fast, 10, initially slow
    accl_f: f32,
};

pub const Sweep = struct {
    opt: SweepInit,
    min_f: proc.SignalSlice,
    max_f: proc.SignalSlice,
    max_time: proc.SignalSlice,
    c_half: proc.SignalSlice,

    pub fn init(sweep_opt: SweepInit) @This() {
        return Sweep{
            .opt = sweep_opt,
            .min_f = @splat(sweep_opt.min_f),
            .max_f = @splat(sweep_opt.max_f),
            .max_time = @splat(sweep_opt.time),
            .c_half = @splat(0.5),
        };
    }

    pub fn deinit(_: @This()) void {}

    pub fn writeSpec(self: *const anyopaque, spec: *proc.ConnectionSpec) void {
        _ = self;
        const id = "Sweep";
        @memcpy(spec.*.id[0..id.len], id);
        spec.*.in_ports[0].type = proc.IODataType.clock;
        spec.*.out_ports[0].type = proc.IODataType.audio;
    }

    pub fn process(self: *anyopaque, io: proc.IOHead) !void {
        const this: *@This() = @ptrCast(@alignCast(self));
        const frames_t_raw: *proc.SignalSlice = io.inputs.port_signals[0];
        const frames_t = @mod(frames_t_raw.*, this.max_time);
        var out: *proc.SignalSlice = io.outputs.port_signals[0];
        //when acc = 1
        //ng_v = min_f + (max_f - min_f) * (t / max_time)
        //ng_disp = integrate ng_v = min_f * t + (max_f - min_f) * t*t / (2 * max_time)
        const ng_disp_rot = this.min_f * frames_t + (this.max_f - this.min_f) * frames_t * frames_t / this.max_time * this.c_half;
        const ng_disp_radians = ng_disp_rot * two_pi;

        //when acc != 1
        // const ng_v = min_freq + std.math.pow(f32, tt / max_time, slow_down) * (max_freq - min_freq); //rotations per second
        out.* = @sin(ng_disp_radians);
    }

    const vtable = proc.Processor.VTable{
        .writeSpec = writeSpec,
        .process = process,
        .leadFrames = null,
        // .deinit = @This().deinit,
    };

    pub fn asProcessor(this: *@This()) proc.Processor {
        return proc.Processor{
            ._this = this,
            ._funcs = &vtable,
        };
    }
};