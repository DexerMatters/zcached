pub const Opcode = enum(u8) {
    ping = 0x00,
    get = 0x01,
    set = 0x02,
    delete = 0x03,
    flush = 0x04,
    dbsize = 0x05,
    save = 0x06,
    mget = 0x07,
    mset = 0x08,
    keys = 0x09,
    sizeof = 0x0A,
    echo = 0x0B,
    rename = 0x0C,
    copy = 0x0D,
};

pub const Operand = enum(u8) {
    simple_string = 0x00,
    string = 0x01,
    integer = 0x02,
    float = 0x03,
    boolean_t = 0x04,
    boolean_f = 0x05,
    null = 0x06,
    array = 0x07,
    map = 0x08,
    unordered_set = 0x09,
    set = 0x0A,
    err = 0x0B,
};

pub const delimiter: [2]u8 = .{ 0x0A, 0x0D }; // LF and CR
