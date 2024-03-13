const std = @import("std");
pub const std_options = struct {
    pub const log_level = std.log.Level.info;
    pub const logFn = myLogFn;
};

pub fn myLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // Ignore all non-error logging from sources other than
    // .my_project, .nice_library and the default
    const scope_prefix = "(" ++ switch (scope) {
        .my_project, .nice_library, std.log.default_log_scope => @tagName(scope),
        else => if (@intFromEnum(level) <= @intFromEnum(std.log.Level.err))
            @tagName(scope)
        else
            return,
    } ++ "): ";

    const prefix = "[" ++ comptime level.asText() ++ "] " ++ scope_prefix;

    // Print the message to stderr, silently ignoring any errors
    std.debug.getStderrMutex().lock();
    defer std.debug.getStderrMutex().unlock();
    const stderr = std.io.getStdErr().writer();
    nosuspend stderr.print(prefix ++ format ++ "\n", args) catch return;
}

const grid = @import("./grid.zig");
const zmq = @cImport({
    @cInclude("zmq.h");
    @cInclude("zmq_utils.h");
});

const soundio = @cImport({
    @cInclude("soundio/soundio.h");
});

const fftw = @cImport({
    @cInclude("fftw3.h");
});

const proc = @import("processor/processor.zig");
const mergeAndSplit = @import("processor/mergeAndSplit.zig");
const output = @import("processor/output.zig");
const sweep = @import("processor/sweep.zig");

//transpose
fn memcpy_hop(dst: []u8, src: []u8, stride: usize) void {
    var i: usize = 0;
    while (i < dst.len) : (i += 1) {
        dst[i] = src[i * stride];
    }
}

pub fn print_device(device: [*c]soundio.SoundIoDevice) void {
    std.log.info("device: {s}", .{device.*.name});
    for (0..@intCast(device.*.sample_rate_count)) |j| {
        const range = device.*.sample_rates[j];
        std.log.info("sample_rate: {d} - {d}", .{ range.min, range.max });
    }

    for (0..@intCast(device.*.layout_count)) |j| {
        const layout = device.*.layouts[j];
        std.log.info("channel_layout: {?s} {d}", .{
            if (layout.name == null) "null" else std.mem.span(layout.name),
            layout.channel_count,
        });
    }
    for (0..@intCast(device.*.format_count)) |j| {
        const format = device.*.formats[j];
        std.log.info("format: {d}", .{format});
    }
}

///Stores a section of Audio data
const TapeSection = struct {

    //number of channels and the start offset for each channel
    channelOffsets: []usize,

    //samples to skip between frames
    frameStride: usize,

    //number of frames in the buffer
    frames: usize,

    //sample rate used to capture the data
    sample_rate: usize,

    //memory buffer
    data: []u8,
};

const TapeLoop = struct {
    allocator: std.mem.Allocator,
    channels: usize,
    sample_rate: usize,
    grids: std.ArrayList(grid.GridStore(f32, null)),
    frames_in_each_grid: usize,
    total_frames: usize,

    fn init(allocator: std.mem.Allocator, channels: usize, sample_rate: usize) TapeLoop {
        var tape = TapeLoop{
            .allocator = allocator,
            .channels = channels,
            .sample_rate = sample_rate,
            .grids = std.ArrayList(grid.GridStore(f32, null)).init(allocator),
            .frames_in_each_grid = std.math.pow(
                usize,
                2,
                //@as(usize, @intFromFloat(@ceil(@log2(@as(f32, @floatFromInt(sample_rate)))))),
                15,
            ),
            .total_frames = 0,
        };

        for (0..2) |_| {
            const g = grid.GridStore(f32, null).init(tape.allocator, tape.channels * tape.frames_in_each_grid) catch {
                @panic("failed to allocate grid");
            };
            @memset(g.memory, 0.0);

            tape.grids.append(g) catch {
                @panic("failed to append grid");
            };
        }

        std.log.info("Tape Created, frames_in_each_grid: {d}, grids {d}", .{ tape.frames_in_each_grid, tape.grids.items.len });
        return tape;
    }

    fn deinit(self: *TapeLoop) void {
        for (self.grids.items) |g| {
            g.deinit();
        }
        self.grids.deinit();
    }

    fn gridStaggerFrames(self: *const TapeLoop) usize {
        const ret = self.frames_in_each_grid / self.grids.items.len;
        if (ret * self.grids.items.len != self.frames_in_each_grid) {
            @panic("frames_in_each_grid not divisible by grids.len");
        }
        return self.frames_in_each_grid / self.grids.items.len;
    }

    fn frameIdxToGridFrameIdx(self: *const TapeLoop, grid_idx: usize, frame_idx: usize) usize {
        return (frame_idx + grid_idx * self.gridStaggerFrames()) % self.frames_in_each_grid;
    }

    fn lastFrameTime(self: *const TapeLoop) f32 {
        return @as(f32, @floatFromInt(self.total_frames)) / @as(f32, @floatFromInt(self.sample_rate));
    }

    fn borrowGrid(self: *const TapeLoop, frames: usize) !grid.GridStore(f32, null) {
        return grid.GridStore(f32, null).init(self.allocator, self.channels * frames);
    }

    fn returnGrid(tape: *TapeLoop, store: grid.GridStore(f32, null)) !void {

        // try tape.grids.append(store);

        //std.log.info("new grid {d}", .{store.memory.len});
        const channelData = store.initViewWithRowCount(tape.channels) catch {
            return error.@"failed to allocate view";
        };
        defer channelData.deinit();

        for (0..tape.channels) |c| {
            const samples = channelData.read_row(c) catch {
                return error.@"failed to read row";
            };

            for (0..tape.grids.items.len) |gidx| {
                const g = tape.grids.items[gidx];
                const grid_frame_start_idx = tape.frameIdxToGridFrameIdx(gidx, tape.total_frames);
                const view = g.initViewWithRowCount(tape.channels) catch {
                    @panic("failed to allocate view");
                };
                defer view.deinit();
                const grid_row = view.read_row(c) catch {
                    return error.@"failed to read row";
                };

                const samplesToCopy = @min(samples.len, grid_row.len - grid_frame_start_idx);
                @memcpy(grid_row[grid_frame_start_idx .. grid_frame_start_idx + samplesToCopy], samples[0..samplesToCopy]);
                //std.log.info("copying grid: {d} channel: {d}, grid_frame_idx: {d} - {d}, samples: {d}", .{ gidx, c, grid_frame_start_idx, grid_frame_start_idx + samplesToCopy, samplesToCopy });

                if (samplesToCopy < samples.len) {
                    @memcpy(grid_row[0 .. samples.len - samplesToCopy], samples[samplesToCopy..samples.len]);
                    // std.log.info("copying grid loopback: {d} channel: {d}, frame: {d}, samples: {d}", .{ gidx, c, 0, samples.len - samplesToCopy });
                }
            }
        }
        store.deinit();
        tape.total_frames += store.memory.len / tape.channels;

        //wait till atleast we have (almost) one full grid worth data
        const safe_frames = tape.frames_in_each_grid - tape.gridStaggerFrames();

        // std.log.info("last frame time: {d}", .{tape.lastFrameTime()});

        //given the total frames, we can calculate the grid index for the grid which has the fullest history
        const max_frame_idx = tape.total_frames;
        const staggers_so_far = (max_frame_idx / tape.gridStaggerFrames()) % tape.grids.items.len;
        //every stagger we need to move to previous grid - 1, starting with tape.grids.items.len - 1
        const grid_to_use = (tape.grids.items.len - staggers_so_far - 1) % tape.grids.items.len;
        const g = tape.grids.items[grid_to_use];

        if (tape.total_frames < safe_frames) {
            // std.log.info("waiting for safe_frames: {d} < {d}", .{ tape.total_frames, safe_frames });
            return;
        }

        const min_frame_idx = tape.total_frames - safe_frames;
        const view = g.initViewWithRowCount(tape.channels) catch {
            @panic("failed to allocate view");
        };
        defer view.deinit();

        const grid_min_frame_idx = tape.frameIdxToGridFrameIdx(grid_to_use, min_frame_idx);
        const grid_max_frame_idx = tape.frameIdxToGridFrameIdx(grid_to_use, max_frame_idx);

        // std.log.info("using grid: {d}[{d}..{d}] for [{d}..{d}]", .{ grid_to_use, grid_min_frame_idx, grid_max_frame_idx, min_frame_idx, max_frame_idx });

        const grid_samples = view.read_row(0) catch {
            return error.@"failed to read row";
        };
        const samples = grid_samples[grid_min_frame_idx..grid_max_frame_idx];
        // std.log.info("samples {}", .{samples.len});

        //initialize noise floor
        if (noise_floor == null) {
            noise_floor = std.ArrayList(f32).initCapacity(tape.allocator, samples.len / 2) catch {
                return error.@"failed to allocate noise_floor";
            };
            noise_floor.?.appendNTimes(0, samples.len / 2) catch {
                return error.@"failed to append noise_floor";
            };
        }
        const nf = noise_floor.?;
        var fft = std.ArrayList(fftw.fftwf_complex).init(tape.allocator);
        fft.resize(samples.len) catch {
            @panic("failed to resize fft");
        };
        defer fft.deinit();

        var fft_mag = std.ArrayList(f32).init(tape.allocator);
        fft_mag.resize(samples.len / 2) catch {
            @panic("failed to resize fft_mag");
        };
        defer fft_mag.deinit();

        const plan = fftw.fftwf_plan_dft_r2c_1d(@intCast(samples.len), &samples.ptr[0], fft.items.ptr, fftw.FFTW_ESTIMATE);
        defer fftw.fftwf_destroy_plan(plan);

        fftw.fftwf_execute(plan);
        const normalizer = 1.0 / @sqrt(@as(f32, @floatFromInt(samples.len)));
        for (0..fft_mag.items.len) |i| {
            fft.items[i][0] *= normalizer;
            fft.items[i][1] *= normalizer;
            fft_mag.items[i] = @sqrt(fft.items[i][0] * fft.items[i][0] + fft.items[i][1] * fft.items[i][1]);
        }

        // debugSpectrum(tape.allocator, "mag", fft_mag.items, nf.items);

        switch (mode) {
            .MeasureNoise => {
                for (0..fft_mag.items.len) |i| {
                    const old = nf.items[i];
                    const new = fft_mag.items[i];
                    if (new > old) {
                        nf.items[i] = new * 0.1 + old * 0.9;
                    } else {
                        nf.items[i] = new * 0.001 + old * 0.999;
                    }
                }

                // debugSpectrum(tape.allocator, "raw", fft_mag.items, null);
                // debugSpectrum(tape.allocator, "clean", fft_mag.items, nf.items);
                // debugSpectrum(tape.allocator, "nf", nf.items, null);

                if (tape.lastFrameTime() > noise_time) {
                    //mode = .Sweep;
                    mode = .None;
                    for (0..nf.items.len) |i| {
                        nf.items[i] = nf.items[i] * 1.5;
                    }
                    debugSpectrum(tape.allocator, "nf", nf.items, null);
                }
            },

            .Sweep, .None => {
                var max_idx: usize = 0;
                var max: f32 = -std.math.inf(f32);

                for (0..fft_mag.items.len) |i| {
                    const mag = (fft_mag.items[i] - nf.items[i]);

                    if (mag > max) {
                        max = mag;
                        max_idx = i;
                    }
                }

                if (max > nf.items[max_idx] * 2.0) {
                    const bucket_width: f32 = @as(f32, @floatFromInt(tape.sample_rate)) / @as(f32, @floatFromInt(samples.len));
                    // const bucket_center: f32 = @as(f32, @floatFromInt(max_idx)) * bucket_width;
                    // const bucket_min: f32 = @max(bucket_center - bucket_width / 2.0, 0);
                    // const bucket_max: f32 = @min(bucket_center + bucket_width / 2.0, @as(f32, @floatFromInt(tape.sample_rate)) / 2.0);
                    // std.log.info("max: {d} Hz - {d} Hz, {d}", .{ bucket_min, bucket_max, max });

                    const min_f: f32 = if (mode == .Sweep) 20.0 else 80.0;
                    const max_f: f32 = if (mode == .Sweep) 20000.0 else 400.0;

                    const debug_min_idx: usize = @intFromFloat(@round(min_f / bucket_width));
                    const debug_max_idx: usize = @intFromFloat(@round(max_f / bucket_width));

                    debugSpectrum(
                        tape.allocator,
                        "mag",
                        fft_mag.items[debug_min_idx..debug_max_idx],
                        nf.items[debug_min_idx..debug_max_idx],
                    );
                }
            },
        }
    }
};

const StreamData = struct {
    allocator: std.mem.Allocator,
    tape: *TapeLoop,
};

var t: f32 = 0.0;

const Mode = enum {
    MeasureNoise,
    Sweep,
    None,
};

var mode = Mode.MeasureNoise;
const noise_time: f32 = 3.0; //time to measure noise floor
var noise_floor: ?std.ArrayList(f32) = null;

const Ramp = struct {
    allocator: std.mem.Allocator,
    slices: [][]const u8,
    memory: []u8,

    fn map(self: @This(), zeroToOneRange: f32) []const u8 {
        const zeroToOne: f32 = std.math.clamp(zeroToOneRange, 0.0, 1.0);
        const slice_idx: usize = @intFromFloat(std.math.floor(zeroToOne * @as(f32, @floatFromInt(self.slices.len - 1))));
        const slice = self.slices[self.slices.len - slice_idx - 1];
        return slice;
    }

    fn deinit(self: @This()) void {
        self.allocator.free(self.memory);
    }

    fn init(allocator: std.mem.Allocator, ramp: []const u8) !Ramp {
        //copy the raw ramp string
        const memory = try allocator.dupe(u8, ramp);

        const utfView = try std.unicode.Utf8View.init(memory);

        var slices = std.ArrayList([]const u8).init(allocator);
        defer slices.deinit();

        var utf8: std.unicode.Utf8Iterator = utfView.iterator();
        while (utf8.nextCodepointSlice()) |cp_str| {
            try slices.append(cp_str);
        }

        return Ramp{
            .allocator = allocator,
            .slices = try slices.toOwnedSlice(),
            .memory = memory,
        };
    }
};

// const char_ramp = "@%#*+=-:.";
// const char_ramp = "@:,.";
// const char_ramp = "$@B%8&WM#*oahkbdpqwmZO0QLCJUYXzcvunxrjft/\\|()1{}[]?-_+~<>i!lI;:,\"^`'. ";
// const _char_ramp = "█▓▒░ ";
const _char_ramp = "█▉▊▋▌▍▎▏'. ";

var char_ramp: Ramp = undefined;

pub fn allocSpectrumString(allocator: std.mem.Allocator, ramp: Ramp, in_spectrum: []f32, nf: ?[]f32) []u8 {
    const spectrum = in_spectrum;
    const buckets: usize = @min(100, spectrum.len);
    var msg = std.ArrayList(u8).initCapacity(allocator, buckets * 4) catch { //*4 for utf8
        @panic("failed to allocate msg");
    };
    defer msg.deinit();

    var sums = allocator.alloc(f32, buckets) catch {
        @panic("failed to allocate sums");
    };
    defer allocator.free(sums);

    var max_sum: f32 = 0.0;

    for (0..buckets) |i| {
        const bucket_start: usize = @max(spectrum.len * i / buckets, 0);
        const bucket_end: usize = @min(spectrum.len * (i + 1) / buckets, spectrum.len);

        var sum: f32 = 0;
        for (bucket_start..bucket_end) |idx| {
            sum += spectrum[idx];
            if (nf != null) {
                sum -= nf.?[idx];
            }
        }
        sum /= @as(f32, @floatFromInt(bucket_end - bucket_start));

        if (sum > max_sum) {
            max_sum = sum;
        }

        sums[i] = sum;
    }

    for (0..buckets) |i| {
        const zeroOneRange = sums[i] / max_sum;
        msg.appendSlice(ramp.map(zeroOneRange)) catch {
            @panic("failed to append slice");
        };
    }

    return msg.toOwnedSlice() catch {
        @panic("failed to toOwnedSlice");
    };
}

pub fn debugSpectrum(allocator: std.mem.Allocator, name: []const u8, spectrum: []f32, nf: ?[]f32) void {
    const spectrum_string = allocSpectrumString(allocator, char_ramp, spectrum, nf);
    defer allocator.free(spectrum_string);
    std.log.info("{s}[{d}]  [{s}]", .{ name, spectrum.len, spectrum_string });
}

pub fn read_callback(stream: [*c]soundio.SoundIoInStream, frame_count_min: c_int, frame_count_max: c_int) callconv(.C) void {
    // std.log.info("read_callback {d} {d}", .{ frame_count_min, frame_count_max });
    _ = frame_count_min;

    var frames_completed: c_int = 0;
    var areas: [*c]soundio.SoundIoChannelArea = null;
    // const format = stream.*.format;
    // const bytes_per_sample = soundio.soundio_get_bytes_per_sample(format);
    const channels: usize = @intCast(stream.*.layout.channel_count);

    const stream_data: *StreamData = @ptrCast(@alignCast(stream.*.userdata));

    while (frames_completed < frame_count_max) {
        var frame_count = frame_count_max - frames_completed;
        const read_start = soundio.soundio_instream_begin_read(stream, &areas, &frame_count);
        if (read_start != 0) {
            std.log.warn("soundio_instream_begin_read failed: {d}", .{read_start});
            break;
        }

        if (frame_count == 0) {
            std.log.warn("frame_count is 0", .{});
            break;
        }

        if (areas == null) {
            std.log.warn("areas is null", .{});
            break;
        }

        const g = stream_data.tape.borrowGrid(@intCast(frame_count)) catch {
            @panic("failed to allocate grid");
        };

        const view = g.initViewWithRowCount(channels) catch {
            @panic("failed to allocate view");
        };
        defer view.deinit();
        for (0..channels) |c| {
            const row = view.read_row(c) catch {
                @panic("failed to read row");
            };
            for (0..@intCast(frame_count)) |f| {
                const ptr = areas[c].ptr + f * @as(usize, @intCast(areas[c].step));
                row[f] = switch (stream.*.bytes_per_sample) {
                    2 => blk2: {
                        const ptrAlign: [*c]align(2) u8 = @alignCast(ptr);
                        break :blk2 switch (stream.*.format) {
                            soundio.SoundIoFormatS16LE => @as(f32, @floatFromInt(@as(*i16, @ptrCast(ptrAlign)).*)) / @as(f32, @floatFromInt(std.math.maxInt(i16))),
                            else => @panic("unsupported format"),
                        };
                    },

                    4 => blk4: {
                        const ptrAlign: [*c]align(4) u8 = @alignCast(ptr);
                        break :blk4 switch (stream.*.format) {
                            soundio.SoundIoFormatFloat32LE => @as(*f32, @ptrCast(ptrAlign)).*,
                            else => @panic("unsupported format"),
                        };
                    },

                    8 => blk8: {
                        const ptrAlign: [*c]align(8) u8 = @alignCast(ptr);
                        break :blk8 switch (stream.*.format) {
                            soundio.SoundIoFormatFloat64LE => @floatCast(@as(*f64, @ptrCast(ptrAlign)).*),
                            else => @panic("unsupported format"),
                        };
                    },

                    else => @panic("unsupported bytes_per_sample"),
                };
            }
        }

        stream_data.tape.returnGrid(g) catch {
            @panic("failed to return grid");
        };

        frames_completed += frame_count;

        // std.log.info("read frame_count: {d}", .{frame_count});
        const read_end = soundio.soundio_instream_end_read(stream);
        if (read_end != 0) {
            std.log.warn("soundio_instream_end_read failed: {d}", .{read_end});
            break;
        }
    }
}

pub fn init_soundio() !struct {
    s: [*c]soundio.SoundIo,
    deinit: *const fn ([*c]soundio.SoundIo) void,
} {
    const s = soundio.soundio_create();
    if (s == null) {
        return error.@"out of memory";
    }
    // defer soundio.soundio_destroy(s);

    const conn_code = soundio.soundio_connect(s);
    if (conn_code != 0) {
        return error.@"soundio_connect failed";
    }
    // defer soundio.soundio_disconnect(s);

    soundio.soundio_flush_events(s);

    return .{
        .s = s,
        .deinit = struct {
            fn deinit(sio: [*c]soundio.SoundIo) void {
                soundio.soundio_disconnect(sio);
                soundio.soundio_destroy(sio);
            }
        }.deinit,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    char_ramp = try Ramp.init(allocator, _char_ramp);
    // try scan_args(allocator);

    for (0..9) |i| {
        std.log.info("{d}", .{i * 3 % 8});
    }

    // const context = zmq.zmq_ctx_new();
    // std.log.info("context: {any}", .{context});

    const sio = try init_soundio();
    const s = sio.s;
    defer sio.deinit(s);

    //default input device
    const default_input_device_idx = soundio.soundio_default_input_device_index(s);
    const default_output_device_idx = soundio.soundio_default_output_device_index(s);

    //make sure we have both device indexes
    if (default_input_device_idx < 0 or default_output_device_idx < 0) {
        std.log.warn("no input or output device", .{});
        return;
    }

    //open input
    const input_device = soundio.soundio_get_input_device(s, default_input_device_idx);
    if (input_device == null) {
        std.log.warn("soundio_get_input_device failed: {d}", .{default_input_device_idx});
        return;
    }
    defer soundio.soundio_device_unref(input_device);

    print_device(input_device);

    //open input stream
    const input_stream = soundio.soundio_instream_create(input_device);
    if (input_stream == null) {
        std.log.warn("soundio_instream_create failed", .{});
        return;
    }
    defer soundio.soundio_instream_destroy(input_stream);

    input_stream.*.read_callback = read_callback;
    input_stream.*.format = soundio.SoundIoFormatFloat32LE;
    input_stream.*.sample_rate = input_device.*.sample_rate_current;
    input_stream.*.layout = input_device.*.current_layout;
    var loop = TapeLoop.init(
        allocator,
        @intCast(input_device.*.current_layout.channel_count),
        @intCast(input_device.*.sample_rate_current),
    );
    defer loop.deinit();
    var stream_data = StreamData{
        .allocator = allocator,
        .tape = &loop,
    };
    input_stream.*.userdata = @ptrCast(&stream_data);

    var factories = try allocator.alloc(proc.ProcessorFactory, 3);

    try sweep.initFactory(&factories[0]);
    try mergeAndSplit.initFactory(&factories[1]);
    try output.initFactory(&factories[2]);
    defer {
        for (factories) |*f| {
            f.deinitFactory();
        }
        allocator.free(factories);
    }

    const procs = try allocator.alloc(proc.Processor, factories.len);
    for (0..factories.len) |i| {
        procs[i] = try factories[i].new(allocator);
    }
    defer {
        for (0..procs.len) |i| {
            factories[i].del(procs[i]);
        }
        allocator.free(procs);
    }

    const out_head = try proc.IOHead.init(allocator, 2, 0);
    const split_head = try proc.IOHead.init(allocator, 1, 2);
    const swp_head = try proc.IOHead.init(allocator, 1, 1);

    const sampling_rate = 44100;

    var frames_idx = std.simd.iota(f32, proc.SignalSliceLength);
    var frames_idx_increment: proc.SignalSlice = @splat(proc.SignalSliceLength);
    const t_per_frame: proc.SignalSlice = @splat(1.0 / @as(f32, @floatFromInt(sampling_rate)));

    var slices = [_]proc.SignalSlice{ @splat(0.0), @splat(0.0), @splat(0.0) };

    swp_head.inputs.port_signals[0] = &slices[0];
    swp_head.outputs.port_signals[0] = &slices[1];

    split_head.inputs.port_signals[0] = &slices[1];
    split_head.outputs.port_signals[0] = &slices[0];
    split_head.outputs.port_signals[1] = &slices[2];

    out_head.inputs.port_signals[0] = &slices[0];
    out_head.inputs.port_signals[1] = &slices[2];

    // var procs = [_]proc.Processor{ swp_proc, split_proc, o_proc };
    var heads = [_]proc.IOHead{ swp_head, split_head, out_head };
    var lead_frames: usize = procs[procs.len - 1].leadFrames();
    var lead_frames_target: usize = 1;

    while (true) {
        const generate = lead_frames < lead_frames_target;

        if (generate) {
            slices[0] = frames_idx * t_per_frame;
            for (0..procs.len) |i| {
                try procs[i].process(heads[i]);
            }
            frames_idx += frames_idx_increment;
        } else {
            const lead_frames_extra = lead_frames - lead_frames_target;
            const seconds_extra = @as(f32, @floatFromInt(lead_frames_extra)) / @as(f32, @floatFromInt(sampling_rate));
            std.time.sleep(@intFromFloat(@round(seconds_extra * std.time.ns_per_s)));
        }

        lead_frames = procs[procs.len - 1].leadFrames();
        if (lead_frames == 0) {
            lead_frames_target *= 2;
            std.log.info("lead_frames_target: {d}", .{lead_frames_target});
        }
    }
}

// fn scan_args(allocator: std.mem.Allocator) !void {
//     var args = try std.process.argsWithAllocator(allocator);
//     defer args.deinit();
//     while (args.next()) |arg| {
//         std.log.info("param {s}", .{arg});
//     }

//     var map = try std.process.getEnvMap(allocator);
//     defer map.deinit();

//     var it = map.iterator();
//     while (it.next()) |entry| {
//         std.log.info("env {s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
//     }

//     std.log.info("{any}", .{std.process.totalSystemMemory()});
// }

test "simple test" {
    // try scan_args(std.testing.allocator);
}
