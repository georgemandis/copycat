// Objective-C runtime bindings for Zig.
// Provides type-safe wrappers around objc_msgSend, NSString, NSData, NSArray.

const std = @import("std");

// ---------------------------------------------------------------------------
// Part 1: Core Obj-C runtime types and extern functions
// ---------------------------------------------------------------------------

// Opaque Objective-C types
pub const Class = *opaque {};
pub const SEL = *opaque {};
pub const id = *opaque {};
pub const NSUInteger = usize;
pub const NSInteger = isize;

// Objective-C runtime functions (from libobjc)
extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) SEL;
extern "objc" fn objc_msgSend() void;

/// Look up an Objective-C class by name. Returns null if not found.
pub fn getClass(name: [*:0]const u8) ?Class {
    return objc_getClass(name);
}

/// Register/look up a selector by name.
pub fn sel(name: [*:0]const u8) SEL {
    return sel_registerName(name);
}

/// Cast objc_msgSend to a typed function pointer.
pub fn msgSendFn(comptime ReturnType: type, comptime ArgTypes: type) MsgSendFnType(ReturnType, ArgTypes) {
    return @ptrCast(&objc_msgSend);
}

fn MsgSendFnType(comptime ReturnType: type, comptime ArgTypes: type) type {
    const args_info = @typeInfo(ArgTypes);
    const fields = args_info.@"struct".fields;

    return switch (fields.len) {
        0 => *const fn (id, SEL) callconv(.c) ReturnType,
        1 => *const fn (id, SEL, fields[0].type) callconv(.c) ReturnType,
        2 => *const fn (id, SEL, fields[0].type, fields[1].type) callconv(.c) ReturnType,
        3 => *const fn (id, SEL, fields[0].type, fields[1].type, fields[2].type) callconv(.c) ReturnType,
        else => @compileError("msgSendFn: too many arguments, add more cases"),
    };
}

/// Send a message to an Objective-C object.
/// All calls in this project return object pointers or integer types, so only
/// objc_msgSend is needed. If future extensions return structs by value on x86_64,
/// objc_msgSend_stret would be required (ARM64 does not use it).
pub fn msgSend(comptime ReturnType: type, target: anytype, selector: SEL, args: anytype) ReturnType {
    const target_as_id: id = @ptrCast(target);
    const ArgsType = @TypeOf(args);
    const func = msgSendFn(ReturnType, ArgsType);

    const args_info = @typeInfo(ArgsType);
    const fields = args_info.@"struct".fields;

    return switch (fields.len) {
        0 => func(target_as_id, selector),
        1 => func(target_as_id, selector, args[0]),
        2 => func(target_as_id, selector, args[0], args[1]),
        3 => func(target_as_id, selector, args[0], args[1], args[2]),
        else => @compileError("msgSend: too many arguments"),
    };
}

// ---------------------------------------------------------------------------
// Part 2: NSString bridging helpers
// ---------------------------------------------------------------------------

/// Create an NSString from a Zig slice. The NSString is autoreleased.
/// Panics via `unreachable` if NSString cannot be found at runtime — this would
/// indicate a fundamentally broken Foundation framework, not a recoverable error.
pub fn nsString(str: [*:0]const u8) id {
    const NSString = getClass("NSString") orelse unreachable;
    return msgSend(id, NSString, sel("stringWithUTF8String:"), .{str});
}

/// Read a UTF-8 C string from an NSString. The pointer is valid as long as the NSString lives.
pub fn fromNSString(nsstr: id) ?[*:0]const u8 {
    return msgSend(?[*:0]const u8, nsstr, sel("UTF8String"), .{});
}

/// Get the length of an NSString (number of UTF-16 code units).
pub fn nsStringLength(nsstr: id) NSUInteger {
    return msgSend(NSUInteger, nsstr, sel("length"), .{});
}

// ---------------------------------------------------------------------------
// Part 3: NSData bridging helpers
// ---------------------------------------------------------------------------

/// Get the raw bytes pointer from an NSData object.
pub fn nsDataBytes(nsdata: id) ?[*]const u8 {
    return msgSend(?[*]const u8, nsdata, sel("bytes"), .{});
}

/// Get the length of an NSData object.
pub fn nsDataLength(nsdata: id) NSUInteger {
    return msgSend(NSUInteger, nsdata, sel("length"), .{});
}

/// Create an NSData from a Zig byte slice. The NSData is autoreleased.
/// For zero-length data, use `nsDataEmpty()` instead — passing an undefined
/// pointer here would be undefined behavior.
/// Panics via `unreachable` if NSData cannot be found at runtime — this would
/// indicate a fundamentally broken Foundation framework, not a recoverable error.
pub fn nsDataFromBytes(bytes: [*]const u8, len: NSUInteger) id {
    const NSData = getClass("NSData") orelse unreachable;
    return msgSend(id, NSData, sel("dataWithBytes:length:"), .{ bytes, len });
}

/// Create an empty NSData. Autoreleased.
/// Panics via `unreachable` if NSData cannot be found at runtime — this would
/// indicate a fundamentally broken Foundation framework, not a recoverable error.
pub fn nsDataEmpty() id {
    const NSData = getClass("NSData") orelse unreachable;
    return msgSend(id, NSData, sel("data"), .{});
}

// ---------------------------------------------------------------------------
// Part 4: NSArray helpers
// ---------------------------------------------------------------------------

/// Get the count of an NSArray.
pub fn nsArrayCount(nsarray: id) NSUInteger {
    return msgSend(NSUInteger, nsarray, sel("count"), .{});
}

/// Get an object from an NSArray at a given index.
pub fn nsArrayObjectAtIndex(nsarray: id, index: NSUInteger) id {
    return msgSend(id, nsarray, sel("objectAtIndex:"), .{index});
}
