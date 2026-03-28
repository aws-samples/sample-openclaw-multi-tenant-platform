# Scale to Zero：KEDA HTTP Add-on

## 目標

Idle tenant pod 自動 scale to 0，有 HTTP request 進來時 30 秒內 scale to 1。
降低多租戶環境中閒置 pod 的運算成本。

## 方案

使用 [KEDA HTTP Add-on](https://github.com/kedacore/http-add-on)（不是 KEDA core 的 HTTP scaler）。

HTTP Add-on 提供獨立的 interceptor proxy，能在 pod 數量為 0 時攔截並暫存 request，
等 pod 啟動後再轉發，實現真正的 scale-to-zero。

## 架構

```
                    ┌─────────────────────────────────────────────┐
                    │                  Kubernetes                  │
                    │                                             │
  Client ──► ALB ──┼──► KEDA HTTP Interceptor Proxy ──► Pod      │
             (host │       (攔截 request，觸發 scale)    (0 or 1) │
             based │                                     │        │
             route)│                                     ▼        │
                    │                                   PVC       │
                    │                                  (gp3 10Gi) │
                    └─────────────────────────────────────────────┘

流程：
1. Pod running   → Interceptor 直接 proxy 到 Pod
2. Pod scaled to 0 → Interceptor 暫存 request，通知 KEDA scale to 1
3. Pod ready      → Interceptor 轉發暫存的 request
```

## 安裝步驟

```bash
# 1. 安裝 KEDA core
helm repo add kedacore https://kedacore.github.io/charts
helm repo update

helm install keda kedacore/keda \
  --namespace keda-system \
  --create-namespace

# 2. 安裝 HTTP Add-on
helm install keda-http-add-on kedacore/keda-add-ons-http \
  --namespace keda-system
```

## Helm Template

新增 `templates/httpscaledobject.yaml`，預設 disabled。

啟用方式：在 tenant 的 values override 中設定：

```yaml
scaleToZero:
  enabled: true
```

完整可調參數（values.yaml 預設值）：

```yaml
scaleToZero:
  enabled: false
  idleTimeout: 900    # 15 分鐘無 request 後 scale to 0
  minReplicas: 0
  maxReplicas: 1
```

啟用 `scaleToZero` 時，Deployment 的 `replicas` 由 KEDA 接管，
需確保 `autoscaling.enabled` 為 false（兩者互斥）。

## 設定參數

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `scaleToZero.enabled` | `false` | 啟用 HTTPScaledObject |
| `scaleToZero.idleTimeout` | `900` | 無流量後幾秒 scale to 0（15 min） |
| `scaleToZero.minReplicas` | `0` | 最小 replica 數 |
| `scaleToZero.maxReplicas` | `1` | 最大 replica 數 |

## 注意事項

- **PVC**：使用 ReadWriteOnce（gp3），scale to 0 時 PVC 不會被刪除，資料保留。
  但 RWO 限制 PVC 只能 attach 到一個 node，maxReplicas 不應超過 1。
- **Cold start 時間**：取決於 image pull（首次或 node 無 cache 時）+ 3 個 init containers
  （init-config、init-skills、init-tools）。預估 15-30 秒（image 已 cache）到 60 秒以上（首次 pull）。
- **Interceptor timeout**：如果 cold start 超過 interceptor 預設 timeout，
  client 會收到 502。可調整 HTTP Add-on 的 `--wait-timeout` 參數。
- **ALB health check**：Pod 為 0 時 ALB target 會變 unhealthy。
  需確認 ALB Ingress 的 routing 指向 interceptor service 而非直接指向 pod service。
- **HPA 互斥**：`scaleToZero.enabled` 和 `autoscaling.enabled` 不應同時啟用。

## 成本影響估算

假設 3 個 tenant，每個 pod request `cpu: 200m, memory: 512Mi`：

| 情境 | 平均 running pods | 月 EC2 成本（相對） |
|------|-------------------|---------------------|
| 無 scale-to-zero | 3 pods × 24h | 100% |
| 平均 idle 70% | 3 × 0.3 = ~0.9 pods | **~40-50% 節省** |

實際節省取決於：
- 各 tenant 的使用時段分佈
- Node 是否能因 pod 減少而被 Cluster Autoscaler 回收
- Spot instance 使用比例
