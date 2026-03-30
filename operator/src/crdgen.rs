use kube::CustomResourceExt;
use tenant_operator::Tenant;

fn main() {
    print!("{}", serde_yaml::to_string(&Tenant::crd()).unwrap());
}
