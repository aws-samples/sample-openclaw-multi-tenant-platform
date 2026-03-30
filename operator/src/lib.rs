use thiserror::Error;

#[derive(Error, Debug)]
pub enum Error {
    #[error("Kube error: {0}")]
    KubeError(#[source] kube::Error),

    #[error("Finalizer error: {0}")]
    FinalizerError(#[source] Box<kube::runtime::finalizer::Error<Error>>),

    #[error("Serialization error: {0}")]
    SerializationError(#[source] serde_json::Error),

    #[error("Missing namespace on tenant {0}")]
    MissingNamespace(String),

    #[error("Helm error: {0}")]
    HelmError(String),

    #[error("Validation error: {0}")]
    ValidationError(String),
}

pub type Result<T, E = Error> = std::result::Result<T, E>;

impl Error {
    pub fn metric_label(&self) -> String {
        format!("{self:?}").to_lowercase()
    }
}

pub mod types;
pub use types::*;

pub mod resources;

pub mod controller;
pub use crate::controller::*;

pub mod metrics;
pub use metrics::Metrics;

pub mod config;

pub mod telemetry;

pub mod webhook;
