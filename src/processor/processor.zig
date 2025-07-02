const std = @import("std");

const specs = @import("specs.zig");
const ZType = @import("../protocol/types.zig").ZType;

pub const ProcessError = error{
    InvalidInstruction,
    InvalidOpcode,
    InvalidOperand,
    ContextEndOfStream,
    ContextError,
    EmptyData,
};

pub const Parser = struct {
    reader: std.io.AnyReader,
    alloc: std.mem.Allocator,

    pub fn init(reader: std.io.AnyReader, alloc: std.mem.Allocator) Self {
        return Self{ .reader = reader, .alloc = alloc };
    }

    pub fn readOpcode(self: *Self) !specs.Opcode {
        const opcode = try self.reader.readAllAlloc(self.alloc, 1);
        defer self.alloc.free(opcode);
        if (opcode.len == 0) {
            return ProcessError.ContextEndOfStream;
        }
        return @enumFromInt(opcode[0]);
    }

    pub fn readOperand(self: *Self, expected_type: specs.Operand) !ZType {
        const operand = try self.reader.readAllAlloc(self.alloc, 1);
        defer self.alloc.free(operand);
        if (operand.len == 0) {
            return ProcessError.ContextEndOfStream;
        }
        if (operand[0] != @intFromEnum(expected_type)) {
            return ProcessError.InvalidOperand;
        }
        return switch (@as(specs.Operand, @enumFromInt(operand[0]))) {
            .simple_string => ZType{ .sstr = self.readSStr() },
            .string => ZType{ .str = self.readStr() },
            .integer => ZType{ .int = self.readInt() },
            .float => ZType{ .float = self.readFloat() },
            .boolean_t => ZType{ .bool = true },
            .boolean_f => ZType{ .bool = false },
            .null => ZType{ .null = {} },
            .array => ZType{ .array = self.readArray() },
            .map => ZType{ .map = self.readMap() },
            .unordered_set => ZType{ .uset = self.readUnorderedSet() },
            .set => ZType{ .set = self.readSet() },
            .err => ZType{ .err = self.readErr() },
            else => ProcessError.InvalidOperand,
        };
    }

    pub fn readSStr(self: *Self) ![]u8 {
        return self.readUtilDelimiterAlloc(self.alloc);
    }

    pub fn readStr(self: *Self) ![]u8 {
        // Read string length (u32)
        const len_bytes = try self.reader.readAllAlloc(self.alloc, 4);
        defer self.alloc.free(len_bytes);
        if (len_bytes.len < 4) {
            return ProcessError.ContextEndOfStream;
        }
        const len = std.mem.readInt(u32, len_bytes, .little);
        if (len == 0) {
            return [_]u8{};
        }

        // Read the string data
        return try self.reader.readAllAlloc(self.alloc, len);
    }

    pub fn readInt(self: *Self) !i64 {
        const int_bytes = try self.reader.readAllAlloc(self.alloc, 8);
        defer self.alloc.free(int_bytes);
        if (int_bytes.len < 8) {
            return ProcessError.ContextEndOfStream;
        }
        return std.mem.readInt(i64, int_bytes, .little);
    }

    pub fn readFloat(self: *Self) !f64 {
        const float_bytes = try self.reader.readAllAlloc(self.alloc, 8);
        defer self.alloc.free(float_bytes);
        if (float_bytes.len < 8) {
            return ProcessError.ContextEndOfStream;
        }
        return @bitCast(float_bytes);
    }

    pub fn readMap(self: *Self) !std.StringHashMap(ZType) {
        const len_bytes = try self.reader.readAllAlloc(self.alloc, 4);
        var map = std.StringHashMap(ZType).init(self.alloc);
        defer self.alloc.free(len_bytes);
        if (len_bytes.len < 4) {
            return ProcessError.ContextEndOfStream;
        }
        const len = std.mem.readInt(u32, len_bytes, .little);
        if (len == 0) {
            return map;
        }

        for (0..len) |_| {
            const key = try self.readSStr();
            const value = try self.readOperand(null);
            if (key.len == 0) {
                return ProcessError.InvalidOperand;
            }
            map.put(key, value);
        }
    }

    pub fn readUtilDelimiterAlloc(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        var array_list: std.ArrayList(u8) = try std.ArrayList.init(u8, allocator);
        while (true) {
            const byte = try self.reader.readAllAlloc(allocator, 1);
            defer allocator.free(byte);
            if (byte.len == 0) {
                break; // End of stream
            }
            if (byte[0] == specs.delimiter[0]) {
                const next_byte = try self.reader.readAllAlloc(allocator, 1);
                defer allocator.free(next_byte);
                if (next_byte.len == 0) {
                    array_list.append(byte[0]);
                    break; // End of stream
                }
                if (next_byte[0] == specs.delimiter[1]) {
                    break; // End of delimiter
                }
                array_list.append(byte[0]);
                array_list.append(next_byte[0]);
            } else {
                array_list.append(byte[0]);
            }
        }
        return array_list.toOwnedSlice();
    }

    const Self = @This();
};

pub const Processor = struct {
    data: []u8,
    data_ptr: usize,
    current: u8,
    is_eof: bool,

    pub fn init(data: []u8) !Processor {
        if (data.len == 0) {
            return ProcessError.EmptyData;
        }

        return Processor{
            .data = data,
            .data_ptr = 0,
            .current = data[0],
            .is_eof = false,
        };
    }

    pub fn next(self: *Processor) !u8 {
        if (self.is_eof) {
            return ProcessError.ContextEndOfStream;
        }

        const byte = self.current;
        self.data_ptr += 1;

        if (self.data_ptr < self.data.len) {
            self.current = self.data[self.data_ptr];
        } else {
            self.is_eof = true;
        }

        return byte;
    }

    pub fn nextN(self: *Processor, n: usize) ![]u8 {
        if (self.data_ptr + n > self.data.len) {
            return ProcessError.ContextEndOfStream;
        }

        const start = self.data_ptr;
        self.data_ptr += n;

        if (self.data_ptr < self.data.len) {
            self.current = self.data[self.data_ptr];
        } else {
            self.is_eof = true;
        }

        return self.data[start..self.data_ptr];
    }

    pub fn nextInstr(self: *Processor) !specs.Opcode {
        const opcode = try self.next();
        return @enumFromInt(opcode);
    }

    pub fn nextOperand(self: *Processor, expected: specs.Operand) !ZType {
        const operand = try self.next();
        if (operand != @intFromEnum(expected)) {
            return ProcessError.InvalidOperand;
        }

        return switch (expected) {
            .simple_string => ZType{ .sstr = self.nextSStr() },
            .string => ZType{ .str = self.nextStr() },
            .integer => ZType{ .int = self.nextInt() },
            .float => ZType{ .float = self.nextFloat() },
            .boolean => ZType{ .bool = self.nextBool() },
            .null => ZType{ .null = null },
            .array => ZType{ .array = self.nextArray() },
            .map => ZType{ .map = self.nextMap() },
            .unordered_set => ZType{ .uset = self.nextUnorderedSet() },
            .set => ZType{ .set = self.nextSet() },
            .err => ZType{ .err = self.nextErr() },
            else => ProcessError.InvalidOperand,
        };
    }

    fn nextSStr(self: *Processor) ![]u8 {
        const start = self.data_ptr;
        while (!self.is_eof) {
            if (self.current == specs.delimiter[0]) {
                if (self.data_ptr + 1 < self.data.len and
                    self.data[self.data_ptr + 1] == specs.delimiter[1])
                {
                    const end = self.data_ptr;
                    _ = try self.next(); // Skip over LF
                    _ = try self.next(); // Skip over CR
                    return self.data[start..end];
                }
            }
            _ = try self.next();
        }
        return ProcessError.ContextEndOfStream;
    }

    fn nextStr(self: *Processor) ![]u8 {
        // Read string length (u32)
        const len_0 = try self.next();
        const len_1 = try self.next();
        const len = std.mem.readInt(u32, .{ len_0, len_1 }, .little);
        if (len == 0) {
            return [_]u8{};
        }

        // Read the string data
        return self.nextN(len);
    }

    fn nextInt(self: *Processor) !i64 {
        return std.mem.readInt(i64, try self.nextN(8), .little);
    }

    fn nextFloat(self: *Processor) !f64 {
        return std.fmt.parseFloat(f64, try self.nextN(8));
    }
};
