const std = @import("std");
const proc = @import("./processor.zig");
const soundio = @cImport({
    @cInclude("soundio/soundio.h");
});

var rand = std.rand.DefaultPrng.init(0);
pub const OutputInit = struct {
    allocator: std.mem.Allocator,
    sampling_rate: usize,
    mutex: *std.Thread.Mutex,
};

pub const Output = struct {
    allocator: std.mem.Allocator,
    mutex: *std.Thread.Mutex,
    soundio: [*c]soundio.SoundIo,
    device: [*c]soundio.SoundIoDevice,
    stream: [*c]soundio.SoundIoOutStream,

    buffer: std.RingBuffer,

    pub fn init(this: *@This(), init_data: OutputInit) !void {
        var allocator = init_data.allocator;
        const buffer_size = init_data.sampling_rate * @sizeOf(f32) * 2;

        this.allocator = allocator;
        // this.soundio = sio;
        this.mutex = init_data.mutex;
        this.device = null;
        this.stream = null;
        this.buffer = try std.RingBuffer.init(allocator, buffer_size);

        errdefer this.deinit();

        this.soundio = soundio.soundio_create();
        if (this.soundio == null) {
            return error.OutOfMemory;
        }

        const conn_code = soundio.soundio_connect(this.soundio);
        if (conn_code != 0) {
            return error.OutOfMemory;
        }

        soundio.soundio_flush_events(this.soundio);

        const default_out_idx = soundio.soundio_default_output_device_index(this.soundio);
        if (default_out_idx < 0) {
            std.log.warn("no output device found", .{});
            return error.OutOfMemory;
        }

        const device = soundio.soundio_get_output_device(this.soundio, default_out_idx);
        if (device == null) {
            std.log.warn("unable to get output device", .{});
            return error.OutOfMemory;
        }
        this.device = device;

        const out_stream = soundio.soundio_outstream_create(this.device);
        if (out_stream == null) {
            std.log.warn("unable to create output stream", .{});
            return error.OutOfMemory;
        }
        this.stream = out_stream;
        out_stream.*.sample_rate = @intCast(init_data.sampling_rate);
        out_stream.*.name = "io-out";
        out_stream.*.format = soundio.SoundIoFormatFloat32NE;
        out_stream.*.layout = .{
            .name = null,
            .channel_count = 2,
            .channels = [_]soundio.SoundIoChannelId{
                soundio.SoundIoChannelIdFrontLeft,
                soundio.SoundIoChannelIdFrontRight,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
                soundio.SoundIoChannelIdInvalid,
            },
        };

        out_stream.*.write_callback = writeCallback_static;
        this.stream.*.userdata = this;

        if (soundio.soundio_outstream_open(this.stream) != soundio.SoundIoErrorNone) {
            std.log.warn("unable to open output stream", .{});
            return error.OutOfMemory;
        }

        if (soundio.soundio_outstream_start(this.stream) != soundio.SoundIoErrorNone) {
            std.log.warn("unable to start output stream", .{});
            return error.OutOfMemory;
        }
    }

    pub fn deinit(this: *@This()) void {
        if (this.stream != null) {
            soundio.soundio_outstream_destroy(this.stream);
        }
        if (this.device != null) {
            soundio.soundio_device_unref(this.device);
        }

        if (this.soundio != null) {
            soundio.soundio_disconnect(this.soundio);
            soundio.soundio_destroy(this.soundio);
        }
    }

    pub fn writeCallback_static(stream: [*c]soundio.SoundIoOutStream, frame_count_min: c_int, frame_count_max: c_int) callconv(.C) void {
        var this: *Output = @ptrCast(@alignCast(stream.*.userdata));
        return this.writeCallback(
            stream,
            @intCast(frame_count_min),
            @intCast(frame_count_max),
        );
    }

    pub fn writeCallback(this: *@This(), stream: [*c]soundio.SoundIoOutStream, frame_count_min: usize, frame_count_max: usize) callconv(.C) void {
        //std.log.info("writeCallback: mutex{*}", .{this.mutex});
        _ = frame_count_min;

        var frames_completed: usize = 0;
        const channels: usize = @intCast(stream.*.layout.channel_count);
        var areas: [*c]soundio.SoundIoChannelArea = undefined;

        while (frames_completed < frame_count_max) {
            var frame_count: c_int = @intCast(frame_count_max - frames_completed);
            areas = null;
            if (soundio.soundio_outstream_begin_write(stream, &areas, &frame_count) != soundio.SoundIoErrorNone) {
                std.log.warn("unable to begin write", .{});
                break;
            }

            if (frame_count == 0) {
                std.log.warn("frame count is 0", .{});
                break;
            }

            if (areas == null) {
                std.log.warn("areas is null", .{});
                break;
            }

            {
                this.mutex.lock();
                defer this.mutex.unlock();

                var buffer = &this.buffer;
                const length = buffer.len();
                if (length % (@sizeOf(f32) * 2) != 0) {
                    @panic("buffer length is not aligned correctly");
                }

                if (length < @sizeOf(f32) * 2 * frame_count) {
                    std.log.warn("buffer length is too short", .{});
                }

                for (0..@intCast(frame_count)) |f| {
                    for (0..channels) |c| {
                        var value: f32 = undefined;
                        if (buffer.len() >= @sizeOf(f32)) {
                            var value_bytes: []u8 = std.mem.asBytes(&value);
                            for (0..@sizeOf(f32)) |i| {
                                value_bytes[i] = buffer.read().?;
                            }
                        } else {
                            value = 2.0 * rand.random().float(f32) - 0.5;
                        }
                        const ptr = areas[c].ptr + f * @as(usize, @intCast(areas[c].step));
                        const ptrAlign: [*c]align(4) u8 = @alignCast(ptr);
                        @as(*f32, @ptrCast(ptrAlign)).* = value;
                    }
                }

                // std.log.info("buffer@r: {d}", .{this.buffer.len()});
            }

            if (soundio.soundio_outstream_end_write(stream) != soundio.SoundIoErrorNone) {
                std.log.warn("unable to end write", .{});
                break;
            }

            frames_completed += @intCast(frame_count);
        }
    }

    pub fn writeSpec(self: *const anyopaque, spec: *proc.ConnectionSpec) void {
        _ = self;
        const id = "Output";
        @memcpy(spec.*.id[0..id.len], id);
        spec.*.in_ports[0].type = proc.IODataType.audio;
        spec.*.in_ports[1].type = proc.IODataType.audio;
    }

    pub fn leadFrames(self: *anyopaque) usize {
        var this: *@This() = @ptrCast(@alignCast(self));
        this.mutex.lock();
        defer this.mutex.unlock();
        return this.buffer.len() / (@sizeOf(f32) * 2);
    }

    pub fn process(self: *anyopaque, io: proc.IOHead) error{OutOfMemory}!void {
        var this: *@This() = @ptrCast(@alignCast(self));
        // pub fn process(this: *@This(), io: proc.IOHead) error{OutOfMemory}!usize {
        // std.log.info("process: mutex{*}", .{this.mutex});

        {
            this.mutex.lock();
            defer this.mutex.unlock();

            const length = this.buffer.len();
            if (length % (@sizeOf(f32) * 2) != 0) {
                @panic("buffer length is not aligned correctly");
            }

            for (0..proc.SignalSliceLength) |i| {
                for (0..2) |c| {
                    var value = io.inputs.port_signals[c][i];
                    var value_bytes = std.mem.asBytes(&value);
                    for (0..@sizeOf(f32)) |j| {
                        this.buffer.write(value_bytes[j]) catch {
                            return error.OutOfMemory;
                        };
                    }
                }
            }

            // std.log.info("buffer@w: {d}", .{this.buffer.len()});
        }

        // soundio.soundio_flush_events(this.soundio);
    }
};

const ProcessorImpl = Output;

const VTable = proc.Processor.VTable{
    .writeSpec = ProcessorImpl.writeSpec,
    .process = ProcessorImpl.process,
    .leadFrames = ProcessorImpl.leadFrames,
};

fn new(_: ?*anyopaque, allocator: std.mem.Allocator) proc.Error!proc.Processor {
    const inner = try allocator.create(ProcessorImpl);
    const mutex = try allocator.create(std.Thread.Mutex);
    mutex.* = std.Thread.Mutex{};
    try inner.init(OutputInit{
        .allocator = allocator,
        .sampling_rate = 44100,
        .mutex = mutex,
    });

    return proc.Processor{
        ._processorImpl = inner,
        ._processorVTable = &VTable,
    };
}

fn del(_: ?*anyopaque, p: proc.Processor) void {
    const inner: *ProcessorImpl = @ptrCast(@alignCast(p._processorImpl));
    const allocator = inner.allocator;
    inner.deinit();
    allocator.destroy(inner.mutex);
    allocator.destroy(inner);
}

pub fn initFactory(f: *proc.ProcessorFactory) proc.Error!void {
    f._deinitFactory = null;

    f._this = null;
    f._new = new;
    f._del = del;
}
