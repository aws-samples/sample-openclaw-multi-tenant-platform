use tracing_subscriber::{EnvFilter, layer::SubscriberExt, util::SubscriberInitExt};

pub fn init() {
    tracing_subscriber::registry()
        .with(
            EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "tenant_operator=info,kube=info".into()),
        )
        .with(tracing_subscriber::fmt::layer().json())
        .init();
}
