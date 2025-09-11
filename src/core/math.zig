const std = @import("std");

pub fn as(T: type) type {
    return struct {
        Vec2: struct {
            x: T,
            y: T,
        },
        Vec3: struct {
            x: T,
            y: T,
            z: T,
        },
        Vec4: struct {
            x: T,
            y: T,
            z: T,
            w: T,
        },
    };
}
