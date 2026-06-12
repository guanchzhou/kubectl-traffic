const std = @import("std");
const app = @import("app");
const model = @import("model");
const prom = @import("prom_client");

test "applyRate folds inbound samples into model keyed by source_workload" {
    const json =
        \\{"status":"success","data":{"resultType":"vector","result":[
        \\{"metric":{"source_workload":"bar","source_workload_namespace":"demo"},"value":[1,"3.5"]}
        \\]}}
    ;
    var v = try prom.parseVector(std.testing.allocator, json);
    defer v.deinit();
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try app.applyRate(&m, .inbound, &v, model.TrafficModel.setRate);
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), m.peer(.inbound, "bar").?.req_per_s, 1e-9);
}

test "applyRate folds outbound samples keyed by destination_workload" {
    const json =
        \\{"status":"success","data":{"resultType":"vector","result":[
        \\{"metric":{"destination_workload":"baz","destination_workload_namespace":"demo"},"value":[1,"5"]}
        \\]}}
    ;
    var v = try prom.parseVector(std.testing.allocator, json);
    defer v.deinit();
    var m = model.TrafficModel.init(std.testing.allocator, 8);
    defer m.deinit();
    try app.applyRate(&m, .outbound, &v, model.TrafficModel.setRate);
    try std.testing.expectApproxEqAbs(@as(f64, 5), m.peer(.outbound, "baz").?.req_per_s, 1e-9);
}
