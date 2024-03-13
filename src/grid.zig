const std = @import("std");

pub fn GridStore(comptime T: type, comptime _alignment: ?usize) type {
    comptime var alignment = _alignment orelse @alignOf(T);

    return struct {
        allocator: std.mem.Allocator,
        memory: []align(alignment) T,

        pub fn init(allocator: std.mem.Allocator, n: usize) error{OutOfMemory}!@This() {
            return @This(){
                .allocator = allocator,
                .memory = try allocator.alignedAlloc(T, alignment, n),
            };
        }

        pub fn deinit(self: @This()) void {
            self.allocator.free(self.memory);
        }

        pub fn initViewWithRowCount(self: @This(), rows: usize) GridError!GridSlice(T, _alignment) {
            return GridSlice(T, _alignment)
                .init(self.allocator, self, self.memory.len / rows);
        }

        pub fn initViewWithColumnCount(self: @This(), columns: usize) GridError!GridSlice(T, _alignment) {
            return GridSlice(T, _alignment)
                .init(self.allocator, self, columns);
        }
    };
}
const GridError = error{ SizeMismatch, OutOfMemory };

pub fn GridSlice(comptime T: type, comptime alignment: ?usize) type {
    return struct {
        allocator: std.mem.Allocator,
        store: GridStore(T, alignment),
        columns_from: usize,
        columns_to: usize,
        row_selection_borders: std.ArrayList(usize),
        row_stride: usize,

        fn init(allocator: std.mem.Allocator, store: GridStore(T, alignment), row_stride: usize) GridError!@This() {
            const rows = store.memory.len / row_stride;
            if (rows * row_stride != store.memory.len) {
                return error.SizeMismatch;
            }

            var all_rows = std.ArrayList(usize).init(allocator);
            try all_rows.append(rows);

            return @This(){
                .allocator = allocator,
                .store = store,
                .columns_from = 0,
                .columns_to = row_stride,
                .row_selection_borders = all_rows,
                .row_stride = row_stride,
            };
        }

        pub fn deinit(self: @This()) void {
            self.row_selection_borders.deinit();
        }

        pub fn row_count(self: @This()) usize {
            var ret: usize = 0;
            for (self.row_selection_borders.items, 0..) |rows, i| {
                if (i % 2 == 0) {
                    ret += rows;
                }
            }
            return ret;
        }

        pub fn column_count(self: @This()) usize {
            return self.columns_to - self.columns_from;
        }

        fn _real_row(self: @This(), index: usize) GridError!usize {
            if (index >= self.row_count()) {
                return error.SizeMismatch;
            }

            var indexLeft: usize = index;

            var real_row: usize = 0;
            var i: usize = 0;
            while (indexLeft > 0) {
                const rows = self.row_selection_borders.items[i];

                if (i % 2 == 1) {
                    real_row += rows;
                } else {
                    const advance = @min(rows, indexLeft);
                    indexLeft -= advance;
                    real_row += advance;
                }
                i += 1;
            }
            return real_row;
        }

        pub fn initViewForRow(self: @This(), index: usize) GridError!GridSlice(T, alignment) {
            var oneRow = std.ArrayList(usize).init(self.allocator);
            try oneRow.append(0);
            try oneRow.append(index);
            try oneRow.append(1);
            try oneRow.append(self.row_count() - index - 1);
            return @This(){
                .allocator = self.allocator,
                .store = self.store,
                .columns_from = self.columns_from,
                .columns_to = self.columns_to,
                .row_selection_borders = oneRow,
                .row_stride = self.row_stride,
            };
        }

        pub fn initViewForColumn(self: @This(), index: usize) GridError!GridSlice(T, alignment) {
            return @This(){
                .allocator = self.allocator,
                .store = self.store,
                .columns_from = index,
                .columns_to = index + 1,
                .row_selection_borders = try self.row_selection_borders.clone(),
                .row_stride = self.row_stride,
            };
        }

        pub fn read_row(self: @This(), index: usize) GridError![]T {
            const fromIdx = (try self._real_row(index)) * self.row_stride;
            const toIdx = fromIdx + self.row_stride;
            const ret: []T = self.store.memory[fromIdx..toIdx];
            return ret;
        }

        /// Copies column wise data to output array. Transposes the data.
        /// The outer dimension of the output array must be equal to the number of rows.
        /// The inner dimension of the output array must be equal to the number of columns.
        pub fn copyColsToRowSlices(self: @This(), dest_rows: [][]f32) GridError!void {
            if (dest_rows.len != self.column_count()) {
                return error.SizeMismatch;
            }

            for (dest_rows, self.columns_from..self.columns_to) |dest_row, src_col_idx| {
                if (dest_row.len != self.row_count()) {
                    return error.SizeMismatch;
                }

                for (0..dest_row.len) |src_row_idx| {
                    dest_row[src_row_idx] = self.store.memory[try self._real_row(src_row_idx) * self.row_stride + src_col_idx];
                }
            }
        }

        pub fn initTranspose(self: *const @This(), dest: GridStore(T, alignment)) GridError!GridSlice(T, alignment) {
            if (self.row_count() * self.column_count() != dest.memory.len) {
                return error.SizeMismatch;
            }

            var destView = try dest.initViewWithRowCount(self.column_count());
            var rowSlicesL = try std.ArrayList([]T).initCapacity(self.allocator, self.column_count());
            defer rowSlicesL.deinit();

            for (0..self.column_count()) |i| {
                try rowSlicesL.append(try destView.read_row(i));
            }

            const rowSlices = rowSlicesL.items;
            try self.copyColsToRowSlices(rowSlices);

            return destView;
        }
    };
}

test "can create and delete store" {
    const allocator = std.testing.allocator;
    var store = try GridStore(f32, null)
        .init(allocator, 1024);
    defer store.deinit();
}

test "can generate simple views" {
    const allocator = std.testing.allocator;
    var store = try GridStore(f32, null)
        .init(allocator, 1024);
    defer store.deinit();

    const rowView = try store.initViewWithRowCount(1);
    defer rowView.deinit();
    try std.testing.expect(rowView.row_count() == 1);
    try std.testing.expect(rowView.column_count() == 1024);
    const rowViewColumn = try rowView.initViewForColumn(512);
    defer rowViewColumn.deinit();
    try std.testing.expect(rowViewColumn.row_count() == 1);
    try std.testing.expect(rowViewColumn.column_count() == 1);

    const columnView = try store.initViewWithColumnCount(1);
    defer columnView.deinit();
    try std.testing.expect(columnView.row_count() == 1024);
    try std.testing.expect(columnView.column_count() == 1);
    const columnViewRow = try columnView.initViewForRow(512);
    defer columnViewRow.deinit();
    try std.testing.expect(columnViewRow.row_count() == 1);
    try std.testing.expect(columnViewRow.column_count() == 1);
}

test "can transpose data" {
    const allocator = std.testing.allocator;
    var store = try GridStore(f32, null)
        .init(allocator, 6);
    defer store.deinit();
    std.mem.copyForwards(f32, store.memory, &[_]f32{ 0.0, 1.0, 2.0, 3.0, 4.0, 5.0 });

    var store2 = try GridStore(f32, null)
        .init(allocator, 6);
    defer store2.deinit();
    std.mem.copyForwards(f32, store2.memory, &[_]f32{ 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 });

    {
        const oneRow = try store.initViewWithRowCount(1);
        defer oneRow.deinit();

        const oneColumn = try oneRow.initTranspose(store2);
        defer oneColumn.deinit();

        try std.testing.expectEqualSlices(f32, store.memory, store2.memory);
    }

    {
        const twoRows = try store.initViewWithRowCount(2);
        defer twoRows.deinit();

        const twoColumn = try twoRows.initTranspose(store2);
        defer twoColumn.deinit();

        var store3 = try GridStore(f32, null)
            .init(allocator, 6);
        defer store3.deinit();

        const twoRowsBack = try twoColumn.initTranspose(store3);
        defer twoRowsBack.deinit();

        try std.testing.expectEqualSlices(f32, store.memory, store3.memory);
    }
}
