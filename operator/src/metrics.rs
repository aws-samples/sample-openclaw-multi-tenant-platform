use prometheus_client::{
    encoding::EncodeLabelSet,
    metrics::{counter::Counter, family::Family},
    registry::Registry,
};
use std::sync::Arc;

#[derive(Clone, Debug, Hash, PartialEq, Eq, EncodeLabelSet)]
pub struct ReconcileLabels {
    pub result: String,
}

pub struct Metrics {
    pub registry: Arc<Registry>,
    pub reconcile_count: Family<ReconcileLabels, Counter>,
}

impl Default for Metrics {
    fn default() -> Self {
        let mut registry = Registry::default();
        let reconcile_count = Family::<ReconcileLabels, Counter>::default();
        registry.register(
            "tenant_reconcile_total",
            "Total tenant reconciliations",
            reconcile_count.clone(),
        );
        Self {
            registry: Arc::new(registry),
            reconcile_count,
        }
    }
}
