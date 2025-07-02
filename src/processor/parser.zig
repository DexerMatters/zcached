const std = @import("std");

const specs = @import("specs.zig");
const ZType = @import("../protocol/types.zig").ZType;

pub const ParserError = error{
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
            return ParserError.ContextEndOfStream;
        }
        return @enumFromInt(opcode[0]);
    }

    pub fn readOperand(self: *Self, expected_type: ?specs.Operand) !ZType {
        const operand = try self.reader.readAllAlloc(self.alloc, 1);
        defer self.alloc.free(operand);
        if (operand.len == 0) {
            return ParserError.ContextEndOfStream;
        }
        if (expected_type) |expected| {
            if (operand[0] != @intFromEnum(expected)) {
                return ParserError.InvalidOperand;
            }
        }
        const operand_enum: specs.Operand = @enumFromInt(operand[0]);
        return switch (operand_enum) {
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
            else => ParserError.InvalidOperand,
        };
    }

    pub fn readSStr(self: *Self) ![]u8 {
        return self.readUtilDelimiterAlloc(self.alloc);
    }

    pub fn readStr(self: *Self) ![]u8 {
        return try self.reader.readAllAlloc(self.alloc, try self.readLength());
    }

    pub fn readInt(self: *Self) !i64 {
        const int_bytes = try self.reader.readAllAlloc(self.alloc, 8);
        defer self.alloc.free(int_bytes);
        if (int_bytes.len < 8) {
            return ParserError.ContextEndOfStream;
        }
        return std.mem.readInt(i64, int_bytes, .little);
    }

    pub fn readFloat(self: *Self) !f64 {
        const float_bytes = try self.reader.readAllAlloc(self.alloc, 8);
        defer self.alloc.free(float_bytes);
        if (float_bytes.len < 8) {
            return ParserError.ContextEndOfStream;
        }
        return @bitCast(float_bytes);
    }

    pub fn readArray(self: *Self) !ZType.Array {
        const len = try self.readLength();
        var array_list = ZType.Array.init(self.alloc, len);
        for (0..len) |_| {
            const value = try self.readOperand(null);
            try array_list.append(value);
        }
        return array_list;
    }

    pub fn readMap(self: *Self) !ZType.Map {
        const len = try self.readLength();
        var map = ZType.Map.init(self.alloc);

        for (0..len) |_| {
            const key = try self.readSStr();
            const value = try self.readOperand(null);
            map.put(key, value);
        }

        return map;
    }

    pub fn readUnorderedSet(self: *Self) !ZType.USet {
        const len = try self.readLength();
        var set = ZType.USet.init(self.alloc);

        for (0..len) |_| {
            const value = try self.readOperand(null);
            try set.insert(value);
        }

        return set;
    }

    pub fn readSet(self: *Self) !ZType.Set {
        const len = try self.readLength();
        var set = ZType.Set.init(self.alloc);

        for (0..len) |_| {
            const value = try self.readOperand(null);
            try set.insert(value);
        }

        return set;
    }

    pub fn readLength(self: *Self) !u32 {
        const len_bytes = try self.reader.readAllAlloc(self.alloc, 4);
        defer self.alloc.free(len_bytes);
        if (len_bytes.len < 4) {
            return ParserError.ContextEndOfStream;
        }
        return std.mem.readInt(u32, len_bytes, .little);
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
