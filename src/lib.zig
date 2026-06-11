/// kubectl_traffic public library surface — re-exports the consumer-facing
/// modules so a downstream build (e.g. c3s) can import a single
/// "kubectl_traffic" module and reach everything it needs.
pub const promql = @import("promql");
pub const prom_client = @import("prom_client");
pub const model = @import("model");
pub const discovery = @import("discovery");
pub const line = @import("render_line");
pub const graph = @import("render_graph");
pub const table = @import("render_table");
