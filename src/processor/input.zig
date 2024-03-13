const std = @import("std");
const proc = @import("./processor.zig");
const soundio = @cImport({
    @cInclude("soundio/soundio.h");
});

var rand = std.rand.DefaultPrng.init(0);
const InputInit = struct {
    allocator: std.mem.Allocator,
    sampling_rate: usize,
    mutex: *std.Thread.Mutex,
};

const Input = struct {
    allocator: std.mem.Allocator,
    mutex: *std.Thread.Mutex,
    soundio: [*c]soundio.SoundIo,
    device: [*c]soundio.SoundIoDevice,
    stream: [*c]soundio.SoundIoInStream,

    buffer: std.RingBuffer,

    pub fn init(this: *@This(), init_data: InputInit) !void {
        var allocator = init_data.allocator;
        const buffer_size = init_data.sampling_rate * @sizeOf(f32);

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

        const default_in_idx = soundio.soundio_default_input_device_index(this.soundio);
        if (default_in_idx < 0) {
            std.log.warn("no input device found", .{});
            return error.OutOfMemory;
        }

        const device = soundio.soundio_get_input_device(this.soundio, default_in_idx);
        if (device == null) {
            std.log.warn("unable to get input device", .{});
            return error.OutOfMemory;
        }
        this.device = device;

        const stream = soundio.soundio_instream_create(this.device);
        if (stream == null) {
            std.log.warn("unable to create input stream", .{});
            return error.OutOfMemory;
        }
        this.stream = stream;
        stream.*.sample_rate = @intCast(init_data.sampling_rate);
        stream.*.name = "io-in";
        stream.*.format = soundio.SoundIoFormatFloat32NE;
        stream.*.layout = .{
            .name = null,
            .channel_count = 1,
            .channels = [_]soundio.SoundIoChannelId{
                soundio.SoundIoChannelIdFrontCenter,
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
                soundio.SoundIoChannelIdInvalid,
            },
        };

        stream.*.read_callback = readCallback_static;
        this.stream.*.userdata = this;

        if (soundio.soundio_instream_open(this.stream) != soundio.SoundIoErrorNone) {
            std.log.warn("unable to open input stream", .{});
            return error.OutOfMemory;
        }

        if (soundio.soundio_instream_start(this.stream) != soundio.SoundIoErrorNone) {
            std.log.warn("unable to start input stream", .{});
            return error.OutOfMemory;
        }
    }

    pub fn deinit(this: *@This()) void {
        if (this.stream != null) {
            soundio.soundio_instream_destroy(this.stream);
        }
        if (this.device != null) {
            soundio.soundio_device_unref(this.device);
        }

        if (this.soundio != null) {
            soundio.soundio_disconnect(this.soundio);
            soundio.soundio_destroy(this.soundio);
        }
    }

    pub fn readCallback_static(stream: [*c]soundio.SoundIoInStream, frame_count_min: c_int, frame_count_max: c_int) callconv(.C) void {
        var this: *Input = @ptrCast(@alignCast(stream.*.userdata));
        return this.readCallback(
            stream,
            @intCast(frame_count_min),
            @intCast(frame_count_max),
        );
    }

    pub fn readCallback(this: *@This(), stream: [*c]soundio.SoundIoInStream, frame_count_min: usize, frame_count_max: usize) callconv(.C) void {
        std.log.info("readCallback: mutex{*}", .{this.mutex});
        _ = frame_count_min;

        var frames_completed: usize = 0;
        const channels: usize = @intCast(stream.*.layout.channel_count);
        var areas: [*c]soundio.SoundIoChannelArea = undefined;

        while (frames_completed < frame_count_max) {
            var frame_count: c_int = @intCast(frame_count_max - frames_completed);
            areas = null;
            if (soundio.soundio_instream_begin_read(stream, &areas, &frame_count) != soundio.SoundIoErrorNone) {
                std.log.warn("unable to begin read", .{});
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

                for (0..@intCast(frame_count)) |f| {
                    for (0..channels) |c| {
                        const ptr = areas[c].ptr + f * @as(usize, @intCast(areas[c].step));
                        const ptrAlign: [*c]align(4) u8 = @alignCast(ptr);
                        var value: f32 = @as(*f32, @ptrCast(ptrAlign)).*;

                        var value_bytes: []u8 = std.mem.asBytes(&value);
                        for (0..@sizeOf(f32)) |i| {
                            if (!buffer.isFull()) {
                                buffer.write(value_bytes[i]) catch {
                                    std.log.warn("unable to write to buffer", .{});
                                };
                            }
                        }
                    }
                }

                std.log.info("in-buffer@w: {d}", .{this.buffer.len()});
            }

            if (soundio.soundio_instream_end_read(stream) != soundio.SoundIoErrorNone) {
                std.log.warn("unable to end read", .{});
                break;
            }

            frames_completed += @intCast(frame_count);
        }
    }

    pub fn writeSpec(this: *@This(), spec: *proc.ConnectionSpec) void {
        _ = this;
        const id = "Input";
        @memcpy(spec.*.id[0..id.len], id);
        spec.*.out_ports[0].type = proc.IODataType.audio;
    }

    pub fn leadFrames(this: *@This()) usize {
        this.mutex.lock();
        defer this.mutex.unlock();
        return this.buffer.len() / (@sizeOf(f32) * 2);
    }

    pub fn process(this: *@This(), io: proc.IOHead) error{OutOfMemory}!void {
        // pub fn process(this: *@This(), io: proc.IOHead) error{OutOfMemory}!usize {
        // std.log.info("process: mutex{*}", .{this.mutex});

        {
            this.mutex.lock();
            defer this.mutex.unlock();

            const length = this.buffer.len();
            if (length % (@sizeOf(f32) * 2) != 0) {
                @panic("buffer length is not aligned correctly");
            }

            var zero_fill: usize = 0;
            if (length / @sizeOf(f32) < proc.SignalSliceLength) {
                zero_fill = @max(0, proc.SignalSliceLength - length / @sizeOf(f32));
            }

            if (zero_fill > 0) {
                std.log.warn("input: buffer length is too short zero-filling {d}", .{zero_fill});
            }

            for (0..proc.SignalSliceLength) |i| {
                for (0..1) |c| {
                    if (i < zero_fill) {
                        io.outputs.port_signals[c][i] = 0.0;
                    } else {
                        var value_bytes = std.mem.asBytes(&io.outputs.port_signals[c][i]);
                        for (0..@sizeOf(f32)) |j| {
                            value_bytes[j] = this.buffer.read().?;
                        }
                    }
                }
            }

            std.log.info("in-buffer@r: {d}", .{this.buffer.len()});
        }

        // soundio.soundio_flush_events(this.soundio);
    }
};

const ProcessorImpl = Input;

const VTable = proc.Processor.VTable{
    .writeSpec = @ptrCast(&ProcessorImpl.writeSpec),
    .process = @ptrCast(&ProcessorImpl.process),
    .leadFrames = @ptrCast(&ProcessorImpl.leadFrames),
};

fn new(_: *proc.ProcessorFactory, allocator: std.mem.Allocator) proc.Error!proc.Processor {
    const inner = try allocator.create(ProcessorImpl);
    const mutex = try allocator.create(std.Thread.Mutex);
    mutex.* = std.Thread.Mutex{};
    try inner.init(InputInit{
        .allocator = allocator,
        .sampling_rate = 44100,
        .mutex = mutex,
    });

    return proc.Processor{
        ._processorImpl = inner,
        ._processorVTable = &VTable,
    };
}

fn del(_: *proc.ProcessorFactory, p: proc.Processor) void {
    const inner: *ProcessorImpl = @ptrCast(@alignCast(p._processorImpl));
    const allocator = inner.allocator;
    inner.deinit();
    allocator.destroy(inner.mutex);
    allocator.destroy(inner);
}

pub fn initFactory() proc.Error!proc.ProcessorFactory {
    const FactoryVTable = proc.ProcessorFactory.VTable{
        .newProcessor = @ptrCast(&new),
        .deleteProcessor = @ptrCast(&del),
    };

    return proc.ProcessorFactory{
        ._factoryImpl = null,
        ._factoryVTable = &FactoryVTable,
    };
}
