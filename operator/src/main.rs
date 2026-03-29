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

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    telemetry::init();
    info!("Starting tenant-operator v{}", env!("CARGO_PKG_VERSION"));

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
