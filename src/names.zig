const std = @import("std");

pub const max_len: usize = 253;

/// DNS-1123 subdomain: 1..253 chars of [a-z0-9-.], starting and ending
/// with an alphanumeric. Covers namespace, Deployment, Pod, and Service names.
pub fn isDns1123(s: []const u8) bool {
    if (s.len == 0 or s.len > max_len) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '.';
        if (!ok) return false;
    }
    return isAlnum(s[0]) and isAlnum(s[s.len - 1]);
}

pub fn validate(s: []const u8) error{InvalidName}!void {
    if (!isDns1123(s)) return error.InvalidName;
}

fn isAlnum(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
}
