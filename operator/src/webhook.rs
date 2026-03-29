use actix_web::{HttpResponse, post, web::Json};
use kube::core::{
    DynamicObject,
    admission::{AdmissionRequest, AdmissionResponse, AdmissionReview},
};
use serde_json::Value;

fn validate_tenant(req: &AdmissionRequest<DynamicObject>) -> AdmissionResponse {
    let resp = AdmissionResponse::from(req);
    let obj = match &req.object {
        Some(o) => o,
        None => return resp.deny("missing object"),
    };

    let data = &obj.data;
    let spec: &Value = match data.get("spec") {
        Some(s) => s,
        None => return resp.deny("missing spec"),
    };

    let mut errors: Vec<String> = Vec::new();

    // Validate tenant name
    if let Some(name) = obj.metadata.name.as_deref()
        && (name.len() > 63
            || name.is_empty()
            || !name
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'))
    {
        errors.push("name must be lowercase alphanumeric/hyphens, 1-63 chars".into());
    }

    // Validate email format
    if let Some(email) = spec.get("email").and_then(|e: &Value| e.as_str())
        && (!email.contains('@')
            || email.len() > 254
            || email.contains('\n')
            || email.contains('\0'))
    {
        errors.push("email must be valid format (max 254 chars, no control characters)".into());
    }

    // Validate budget.monthlyUSD > 0 if set
    if let Some(monthly) = spec
        .get("budget")
        .and_then(|b: &Value| b.get("monthlyUSD"))
        .and_then(|m: &Value| m.as_i64())
        && monthly <= 0
    {
        errors.push("budget.monthlyUSD must be > 0".into());
    }

    // Validate skills: alphanumeric + hyphens only
    if let Some(skills) = spec.get("skills").and_then(|s: &Value| s.as_array()) {
        for s in skills.iter().filter_map(|v: &Value| v.as_str()) {
            if !s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-') {
                errors.push(format!("skill '{s}' must be alphanumeric/hyphens only"));
            }
        }
    }

    if errors.is_empty() {
        resp
    } else {
        resp.deny(errors.join("; "))
    }
}

#[post("/validate-tenant")]
pub async fn validate_tenant_handler(body: Json<AdmissionReview<DynamicObject>>) -> HttpResponse {
    let req: AdmissionRequest<DynamicObject> = match body.into_inner().try_into() {
        Ok(r) => r,
        Err(e) => return HttpResponse::BadRequest().body(format!("invalid review: {e}")),
    };
    let resp = validate_tenant(&req);
    HttpResponse::Ok().json(resp.into_review())
}
