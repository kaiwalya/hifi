const std = @import("std");

const proc = @import("./processor.zig");

const MergeAndSplit = struct {
    allocator: std.mem.Allocator,

    pub fn init(this: *@This(), allocator: std.mem.Allocator) void {
        this.allocator = allocator;
    }

    pub fn deinit(_: @This()) void {}

    pub fn writeSpec(self: *const anyopaque, spec: *proc.ConnectionSpec) void {
        _ = self;
        @memcpy(spec.*.id[0.."merge".len], "merge");
        for (&spec.*.in_ports) |*port| {
            port.type = proc.IODataType.audio;
        }

        for (&spec.*.out_ports) |*port| {
            port.type = proc.IODataType.audio;
        }
    }

    pub fn process(self: *anyopaque, io: proc.IOHead) !void {
        _ = self;
        const outputs = io.outputs;
        var last_output_slice: ?*proc.SignalSlice = null;
        for (outputs.port_signals) |outputSignal| {
            if (last_output_slice != null) {
                outputSignal.* = last_output_slice.?.*;
                continue;
            }
            last_output_slice = outputSignal;
            outputSignal.* = @splat(0.0);

            const inputs = io.inputs;
            for (inputs.port_signals) |input_signal| {
                outputSignal.* += input_signal.*;
            }
        }
    }
};

const ProcessorImpl = MergeAndSplit;

const VTable = proc.Processor.VTable{
    .writeSpec = ProcessorImpl.writeSpec,
    .process = ProcessorImpl.process,
    .leadFrames = null,
};

fn new(_: ?*anyopaque, allocator: std.mem.Allocator) proc.Error!proc.Processor {
    const inner = try allocator.create(ProcessorImpl);
    inner.init(allocator);

    return proc.Processor{
        ._processorImpl = inner,
        ._processorVTable = &VTable,
    };
}

fn del(_: ?*anyopaque, p: proc.Processor) void {
    const inner: *ProcessorImpl = @ptrCast(@alignCast(p._processorImpl));
    const allocator = inner.allocator;
    inner.deinit();
    allocator.destroy(inner);
}

pub fn initFactory(f: *proc.ProcessorFactory) proc.Error!void {
    f._deinitFactory = null;

    f._this = null;
    f._new = new;
    f._del = del;
}

test "merge passes the right id" {
    var spec = proc.ConnectionSpec.init();
    defer spec.deinit();
    MergeAndSplit.writeSpec(&spec);
    try std.testing.expect(spec.in_ports[0].type == proc.IODataType.audio);
    try std.testing.expect(spec.in_ports[spec.in_ports.len - 1].type == proc.IODataType.audio);
    try std.testing.expect(spec.out_ports[0].type == proc.IODataType.audio);
    try std.testing.expect(spec.out_ports[spec.out_ports.len - 1].type == proc.IODataType.audio);
    try std.testing.expectEqualStrings(spec.id[0.."merge".len], "merge");
}

test "works with no inputs or outputs" {
    var merge = MergeAndSplit.init(std.testing.allocator);
    defer merge.deinit();
    const ioHead = try proc.IOHead.init(std.testing.allocator, 0, 0);
    defer ioHead.deinit();
    merge.process(ioHead);
}

test "works with no inputs" {
    var merge = MergeAndSplit.init(std.testing.allocator);
    defer merge.deinit();
    var io_head = try proc.IOHead.init(std.testing.allocator, 0, 2);
    defer io_head.deinit();
    io_head.outputs.port_signals[0] = @splat(1.0);
    io_head.outputs.port_signals[1] = @splat(1.0);
    merge.process(io_head);
    try std.testing.expectEqual(@as(proc.SignalSlice, @splat(0.0)), io_head.outputs.port_signals[0]);
    try std.testing.expectEqual(io_head.outputs.port_signals[0], io_head.outputs.port_signals[1]);
}

test "works with one inputs" {
    var merge = MergeAndSplit.init(std.testing.allocator);
    defer merge.deinit();
    var io_head = try proc.IOHead.init(std.testing.allocator, 1, 2);
    defer io_head.deinit();
    io_head.inputs.port_signals[0] = std.simd.iota(f32, proc.SignalSliceLength);
    io_head.outputs.port_signals[0] = @splat(1.0);
    io_head.outputs.port_signals[1] = @splat(1.0);

    merge.process(io_head);

    try std.testing.expectEqual(std.simd.iota(f32, proc.SignalSliceLength), io_head.outputs.port_signals[0]);
    try std.testing.expectEqual(io_head.outputs.port_signals[0], io_head.outputs.port_signals[1]);
}

test "works with two inputs" {
    var merge = MergeAndSplit.init(std.testing.allocator);
    defer merge.deinit();
    var io_head = try proc.IOHead.init(std.testing.allocator, 2, 2);
    defer io_head.deinit();
    io_head.inputs.port_signals[0] = std.simd.iota(f32, proc.SignalSliceLength);
    io_head.inputs.port_signals[1] = std.simd.iota(f32, proc.SignalSliceLength);
    io_head.outputs.port_signals[0] = @splat(1.0);
    io_head.outputs.port_signals[1] = @splat(1.0);

    merge.process(io_head);

    try std.testing.expectEqual(std.simd.iota(f32, proc.SignalSliceLength) + std.simd.iota(f32, proc.SignalSliceLength), io_head.outputs.port_signals[0]);
    try std.testing.expectEqual(io_head.outputs.port_signals[0], io_head.outputs.port_signals[1]);
}
