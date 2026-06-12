const std = @import("std");
const pc = @import("prom_client");

const sample =
    \\{"status":"success","data":{"resultType":"vector","result":[
    \\{"metric":{"source_workload":"bar","source_workload_namespace":"demo"},"value":[1718000000,"3.5"]},
    \\{"metric":{"source_workload":"auth-ws","source_workload_namespace":"demo"},"value":[1718000000,"1"]}
    \\]}}
;

test "parse instant vector into samples keyed by labels" {
    var res = try pc.parseVector(std.testing.allocator, sample);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 2), res.samples.len);
    try std.testing.expectEqualStrings("bar", res.samples[0].labels.get("source_workload").?);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), res.samples[0].value, 1e-9);
}

test "parse empty result yields zero samples" {
    const empty = "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[]}}";
    var res = try pc.parseVector(std.testing.allocator, empty);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 0), res.samples.len);
}

test "NaN string value parses to nan" {
    const nanjson = "{\"status\":\"success\",\"data\":{\"resultType\":\"vector\",\"result\":[{\"metric\":{\"x\":\"y\"},\"value\":[1,\"NaN\"]}]}}";
    var res = try pc.parseVector(std.testing.allocator, nanjson);
    defer res.deinit();
    try std.testing.expect(std.math.isNan(res.samples[0].value));
}
