use actix_web::{App, HttpRequest, HttpResponse, HttpServer, get, web::Data};
use tenant_operator::{State, controller, telemetry, webhook};
use tracing::*;

#[get("/health")]
async fn health(_: HttpRequest) -> HttpResponse {
    HttpResponse::Ok().json(serde_json::json!({"status": "ok"}))
}

#[get("/metrics")]
async fn metrics(state: Data<State>) -> HttpResponse {
    let body = state.metrics();
    HttpResponse::Ok()
        .content_type("text/plain; charset=utf-8")
        .body(body)
}

#[get("/")]
async fn index(state: Data<State>) -> HttpResponse {
    let _d = state.diagnostics().await;
    HttpResponse::Ok().json(serde_json::json!({
        "version": env!("CARGO_PKG_VERSION"),
    }))
}

/// Validate that critical env vars are not CDK/sed placeholders.
/// Returns error instead of silently creating broken resources.
fn validate_env() -> anyhow::Result<()> {
    const KNOWN_PLACEHOLDERS: &[&str] = &[
        "REGION",
        "DOMAIN",
        "COGNITO_POOL_ARN",
        "COGNITO_CLIENT_ID",
        "COGNITO_DOMAIN",
        "GATEWAY_DOMAIN",
        "https://github.com/ORG/REPO.git",
    ];
    let required = [
        ("AWS_REGION", "AWS region (e.g. us-west-2)"),
        ("GATEWAY_DOMAIN", "Gateway domain (e.g. claw.example.com)"),
    ];
    let mut errors = Vec::new();
    for (key, desc) in &required {
        match std::env::var(key) {
            Ok(val) if KNOWN_PLACEHOLDERS.contains(&val.as_str()) => {
                errors.push(format!(
                    "  {key}={val} (placeholder — run setup.sh or sed to inject real values)"
                ));
            }
            Ok(val) if val.is_empty() => {
                errors.push(format!("  {key} is empty — expected: {desc}"));
            }
            Err(_) => {
                errors.push(format!("  {key} not set — expected: {desc}"));
            }
            Ok(_) => {} // valid
        }
    }
    if !errors.is_empty() {
        let msg = format!(
            "Fatal: Operator env vars contain placeholders or are missing.\n\
             This means setup.sh sed substitution did not run.\n\
             Fix: re-run setup.sh or manually set env vars.\n\n{}",
            errors.join("\n")
        );
        error!("{}", msg);
        eprintln!("{}", msg);
        anyhow::bail!("Environment validation failed");
    }
    Ok(())
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // --version flag: print version and exit (no K8s connection needed)
    if std::env::args().any(|a| a == "--version" || a == "-V") {
        println!("tenant-operator {}", env!("CARGO_PKG_VERSION"));
        return Ok(());
    }

    telemetry::init();
    info!("Starting tenant-operator v{}", env!("CARGO_PKG_VERSION"));

    validate_env()?;

    let state = State::default();
    let controller = controller::run(state.clone());

    let server = HttpServer::new(move || {
        App::new()
            .app_data(Data::new(state.clone()))
            .service(health)
            .service(metrics)
            .service(index)
            .service(webhook::validate_tenant_handler)
    })
    .bind("0.0.0.0:8080")?
    .shutdown_timeout(5);

    // Run controller and web server concurrently
    tokio::select! {
        _ = controller => {},
        result = server.run() => {
            if let Err(e) = result {
                error!("Web server failed: {}", e);
            }
        }
    };
    Ok(())
}
