# OpenClaw Image 自動更新方案

## 問題

目前 OpenClaw 升版流程是手動操作：

1. 確認新版 image tag（`ghcr.io/openclaw/openclaw`）
2. 修改 `helm/charts/openclaw-platform/values.yaml` 的 `image.tag`
3. 對 3 個 tenant（alice, bob, carol）分別跑 `helm upgrade`

3 個 tenant 在獨立 namespace（`openclaw-alice`, `openclaw-bob`, `openclaw-carol`），每次升版要重複三次，容易漏掉或版本不一致。

## 方案比較

| 方案 | 做法 | Pros | Cons |
|------|------|------|------|
| **A: Flux Image Automation** | Flux image reflector + image automation controller，偵測新 tag 後自動發 PR 更新 Git repo | GitOps native；自動發 PR 可 review | 需要裝 Flux 全套（source-controller, kustomize-controller, image-reflector, image-automation）；對 3 tenants 來說太重 |
| **B: ArgoCD Image Updater** | ArgoCD 的 image updater plugin，annotation-based 設定 | 輕量，只需一個 sidecar；支援多種 update strategy | 前提是要用 ArgoCD；我們目前沒有裝 |
| **C: CronJob + kubectl** | K8s CronJob 定期檢查 registry，有新版就 `kubectl set image` | 零額外依賴；邏輯簡單透明；可以直接發 Telegram 通知 | 不是 GitOps（values.yaml 不會自動更新）；需要 ServiceAccount 有 deployment update 權限 |
| **D: GitHub Actions** | CI workflow 偵測新 image push，跑 `helm upgrade` | 在 CI 裡做，有 audit trail | 需要 kubeconfig access（self-hosted runner 或 secrets）；多一層網路依賴 |

## 推薦方案：C（CronJob + kubectl）

理由：
- 只有 3 個 tenant，不需要 GitOps 全套基礎設施
- 零額外元件安裝，cluster 內原生 CronJob 就能跑
- 出問題時 debug 簡單（就是一個 shell script）
- 搭配 Telegram 通知，升版有感知

## CronJob 設計

### 流程

```
每 6 小時 → 查 ghcr.io latest tag → 比對目前 running tag
                                          │
                              ┌────────────┴────────────┐
                              │ 相同                     │ 不同
                              │ → 不做事                 │ → kubectl set image (3 tenants)
                              │                          │ → 發 Telegram 通知
                              └─────────────────────────┘
```

### 核心 Script

```bash
#!/bin/bash
set -euo pipefail

IMAGE="ghcr.io/openclaw/openclaw"
TENANTS="alice bob carol"
DEPLOY_NAME="openclaw-platform"
CONTAINER_NAME="openclaw"
TG_BOT_TOKEN="${TG_BOT_TOKEN}"
TG_CHAT_ID="${TG_CHAT_ID}"

# 取得 registry 最新 tag（用 crane）
LATEST=$(crane ls "$IMAGE" | grep -E '^[0-9]{4}\.[0-9]+\.[0-9]+$' | sort -V | tail -1)

# 取得目前 running tag（從第一個 tenant 取）
CURRENT=$(kubectl -n openclaw-alice get deploy "$DEPLOY_NAME" \
  -o jsonpath="{.spec.template.spec.containers[0].image}" | cut -d: -f2)

if [ "$LATEST" = "$CURRENT" ]; then
  echo "已是最新版 $CURRENT，不更新"
  exit 0
fi

echo "發現新版: $CURRENT → $LATEST"

for tenant in $TENANTS; do
  kubectl -n "openclaw-${tenant}" set image "deploy/${DEPLOY_NAME}" \
    "${CONTAINER_NAME}=${IMAGE}:${LATEST}"
  kubectl -n "openclaw-${tenant}" rollout status "deploy/${DEPLOY_NAME}" --timeout=300s
done

# Telegram 通知
MSG="🔄 OpenClaw 已自動更新: ${CURRENT} → ${LATEST}"
curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TG_CHAT_ID}" -d text="${MSG}"
```

### CronJob Manifest

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: openclaw-image-updater
  namespace: openclaw-system
spec:
  schedule: "0 */6 * * *"  # 每 6 小時
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: image-updater
          containers:
          - name: updater
            image: ghcr.io/google/go-containerregistry/crane:latest
            command: ["/bin/sh", "/scripts/update.sh"]
            env:
            - name: TG_BOT_TOKEN
              valueFrom:
                secretKeyRef:
                  name: telegram-credentials
                  key: bot-token
            - name: TG_CHAT_ID
              valueFrom:
                secretKeyRef:
                  name: telegram-credentials
                  key: chat-id
            volumeMounts:
            - name: script
              mountPath: /scripts
          restartPolicy: OnFailure
          volumes:
          - name: script
            configMap:
              name: image-updater-script
              defaultMode: 0755
```

### RBAC

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: image-updater
  namespace: openclaw-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: image-updater
  namespace: openclaw-alice
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "patch"]
# bob, carol 各 namespace 同樣建一份 Role + RoleBinding
```

## 實作步驟

```bash
# 1. 建立 namespace
kubectl create namespace openclaw-system

# 2. 建立 Telegram secret
kubectl -n openclaw-system create secret generic telegram-credentials \
  --from-literal=bot-token="<TG_BOT_TOKEN>" \
  --from-literal=chat-id="<TG_CHAT_ID>"

# 3. 建立 script ConfigMap
kubectl -n openclaw-system create configmap image-updater-script \
  --from-file=update.sh=scripts/image-update.sh

# 4. 建立 ServiceAccount + RBAC（每個 tenant namespace）
for ns in openclaw-alice openclaw-bob openclaw-carol; do
  kubectl -n "$ns" apply -f rbac/image-updater-role.yaml
  kubectl -n "$ns" create rolebinding image-updater \
    --role=image-updater \
    --serviceaccount=openclaw-system:image-updater
done

# 5. 部署 CronJob
kubectl -n openclaw-system apply -f cronjob/image-updater.yaml

# 6. 手動測試一次
kubectl -n openclaw-system create job --from=cronjob/openclaw-image-updater test-update
kubectl -n openclaw-system logs -f job/test-update
```

## 風險與緩解

| 風險 | 影響 | 緩解措施 |
|------|------|----------|
| Auto-update 引入 breaking change | 服務中斷 | **只 auto-update patch version**：script 裡加版本比對，major/minor 變動時只通知不更新 |
| Registry 暫時不可達 | CronJob 失敗 | `restartPolicy: OnFailure` + 6 小時後自動重試 |
| Rollout 失敗 | 部分 tenant 卡在更新中 | `rollout status --timeout=300s` 會 fail，搭配 Telegram 通知人工介入 |
| Image pull 失敗 | Pod CrashLoopBackOff | Deployment 預設 rollback 策略會保留舊 ReplicaSet |

### Patch-only 版本過濾

在 script 加入版本比對邏輯：

```bash
CURRENT_MAJOR=$(echo "$CURRENT" | cut -d. -f1)
LATEST_MAJOR=$(echo "$LATEST" | cut -d. -f1)
CURRENT_MINOR=$(echo "$CURRENT" | cut -d. -f2)
LATEST_MINOR=$(echo "$LATEST" | cut -d. -f2)

if [ "$CURRENT_MAJOR" != "$LATEST_MAJOR" ] || [ "$CURRENT_MINOR" != "$LATEST_MINOR" ]; then
  MSG="⚠️ OpenClaw 有 major/minor 更新: ${CURRENT} → ${LATEST}，需手動升級"
  curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT_ID}" -d text="${MSG}"
  exit 0
fi
```
