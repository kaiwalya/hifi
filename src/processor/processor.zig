const std = @import("std");

pub const IODataType = enum {
    none,
    clock,
    audio,
    control,
};

pub const Error = error{
    OutOfMemory,
};

pub const InputPortSpec = struct { type: IODataType };

pub const OutputPortSpec = struct { type: IODataType };

pub const IOPortCount = 2;

pub const ConnectionSpec = struct {
    id: [32]u8,
    in_ports: [IOPortCount]InputPortSpec,
    out_ports: [IOPortCount]OutputPortSpec,

    pub fn init() @This() {
        return @This(){
            .id = [_]u8{0} ** 32,
            .in_ports = [_]InputPortSpec{.{ .type = .none }} ** IOPortCount,
            .out_ports = [_]OutputPortSpec{.{ .type = .none }} ** IOPortCount,
        };
    }

    pub fn deinit(self: @This()) void {
        _ = self;
    }
};

pub const Processor = struct {
    pub const VTable = struct {
        writeSpec: *const fn (this: *const anyopaque, spec: *ConnectionSpec) void,
        process: *const fn (this: *anyopaque, head: IOHead) anyerror!void,
        leadFrames: ?*const fn (this: *anyopaque) usize,
    };

    _processorImpl: *anyopaque,
    _processorVTable: *const VTable,

    pub fn writeSpec(this: *@This(), spec: *ConnectionSpec) void {
        const writeSpec_fn = this._processorVTable.writeSpec;
        writeSpec_fn(this._processorImpl, spec);
    }

    pub fn process(this: *@This(), head: IOHead) !void {
        const process_fn = this._processorVTable.process;
        return process_fn(this._processorImpl, head);
    }

    pub fn leadFrames(this: *@This()) usize {
        const leadFrames_fn = this._processorVTable.leadFrames;
        if (leadFrames_fn == null) {
            return 0;
        }
        return leadFrames_fn.?(this._processorImpl);
    }
};

pub const ProcessorFactory = struct {
    _deinitFactory: ?*const fn (this: *ProcessorFactory) void,
    _this: ?*anyopaque,
    _new: *const fn (this: ?*anyopaque, allocator: std.mem.Allocator) Error!Processor,
    _del: *const fn (this: ?*anyopaque, processor: Processor) void,

    pub fn deinitFactory(this: *@This()) void {
        if (this._deinitFactory != null) {
            this._deinitFactory.?(this);
        }
    }

    pub fn new(this: *const @This(), allocator: std.mem.Allocator) Error!Processor {
        return this._new(this._this, allocator);
    }

    pub fn del(this: *const @This(), processor: Processor) void {
        this._del(this._this, processor);
    }
};

pub const SignalSliceLength = 32;
pub const SignalSlice = @Vector(SignalSliceLength, f32);

///Represents a slice of input timeline.
pub const IOHead = struct {
    allocator: std.mem.Allocator,

    inputs: struct {
        //connected input port indexes
        port_indices: []usize,

        //signals from the connected ports
        port_signals: []*SignalSlice,
    },

    outputs: struct {
        //connected output port indices
        port_indices: []usize,

        //outgoing signals to ports whose indexes are in port_indices
        port_signals: []*SignalSlice,
    },

    pub fn init(allocator: std.mem.Allocator, ins: usize, outs: usize) Error!@This() {
        var ints = try allocator.alloc(usize, ins + outs);
        var slices = try allocator.alloc(*SignalSlice, ins + outs);

        var ret = @This(){
            .allocator = allocator,
            .inputs = .{
                .port_indices = ints[0..ins],
                .port_signals = slices[0..ins],
            },
            .outputs = .{
                .port_indices = ints[ins .. ins + outs],
                .port_signals = slices[ins .. ins + outs],
            },
        };

        for (0..ret.inputs.port_indices.len) |i| {
            ret.inputs.port_indices[i] = i;
        }

        for (0..ret.outputs.port_indices.len) |i| {
            ret.outputs.port_indices[i] = i;
        }

        // const zeroSlice: SignalSlice = @splat(0.0);
        // @memset(slices, zeroSlice);

        return ret;
    }

    pub fn deinit(self: @This()) void {
        const allocator = self.allocator;
        const ins = self.inputs.port_indices.len;
        const outs = self.outputs.port_indices.len;

        allocator.free(self.inputs.port_indices.ptr[0 .. ins + outs]);
        allocator.free(self.inputs.port_signals.ptr[0 .. ins + outs]);
    }
};

test "ConnectionSpec: init initializes the memory" {
    var spec = ConnectionSpec.init();
    defer spec.deinit();

    try std.testing.expect(spec.id.len > 0);
    try std.testing.expect(spec.in_ports.len > 0);
    try std.testing.expect(spec.out_ports.len > 0);

    for (spec.id) |c| {
        try std.testing.expectEqual(c, 0);
    }

    for (spec.in_ports) |i| {
        try std.testing.expectEqual(i.type, .none);
    }

    for (spec.out_ports) |o| {
        try std.testing.expectEqual(o.type, .none);
    }
}

test "IOHead: init initializes the memory" {
    var allocator = std.testing.allocator;
    var head = try IOHead.init(allocator, 2, 2);
    defer head.deinit();

    try std.testing.expect(head.inputs.port_indices.len == 2);
    try std.testing.expect(head.inputs.port_signals.len == 2);
    try std.testing.expect(head.outputs.port_indices.len == 2);
    try std.testing.expect(head.outputs.port_signals.len == 2);
    try std.testing.expect(head.inputs.port_indices[0] == 0);
    try std.testing.expect(head.inputs.port_indices[1] == 1);
}
