# ArgoCD

## 架構

ArgoCD 透過 CDK Helm chart 安裝在 `argocd` namespace，使用 [argo-helm](https://github.com/argoproj/argo-helm) chart v7.8.0。

主要元件：
- **argocd-server** — API server + Web UI（ClusterIP，透過 port-forward 存取）
- **argocd-repo-server** — Git repo 同步
- **argocd-application-controller** — 監控 desired state vs live state，執行 sync

設定 `server.insecure: true` 讓 server 不做 TLS termination（由前端 LB/ingress 處理）。

## 存取 UI

```bash
# 取得 admin 密碼
./scripts/setup-argocd.sh

# port-forward
kubectl port-forward svc/argocd-server -n argocd 8080:443

# 開啟 https://localhost:8080
```

## 部署 Application

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo.git
    targetRevision: main
    path: k8s/
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## 注意事項

- 初始 admin 密碼存在 `argocd-initial-admin-secret`，首次登入後建議更換
- Production 環境應設定 SSO（Cognito / OIDC）取代 admin 帳號
- ArgoCD 的 server 設為 ClusterIP，不直接暴露；需要外部存取時透過 Ingress + ALB
