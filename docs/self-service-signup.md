# 自助註冊 + HC 審核 + 自動建 Tenant

## 目標

使用者透過 Cognito Hosted UI 自行註冊帳號，HC 在 Cognito Console 審核確認後，系統自動執行 create-tenant 流程（Secrets Manager → Pod Identity → Helm install），最終通知使用者其專屬 URL。

## 架構

```
User ──→ Cognito Hosted UI ──→ 註冊（email + password）
                                  │
                                  ▼
                          Pre-sign-up Lambda
                          ├─ autoConfirmUser = false（需 HC 審核）
                          ├─ autoVerifyEmail = true
                          └─ SNS 通知 HC「新註冊：{email}」
                                  │
                                  ▼
                          HC 在 Cognito Console 確認使用者
                                  │
                                  ▼
                          Post-confirmation Lambda
                          ├─ email → tenant name（sanitize）
                          ├─ Secrets Manager: openclaw/{tenant}/gateway-token
                          ├─ EKS Pod Identity Association
                          └─ Helm install（透過 Step Functions 或 CodeBuild）
                                  │
                                  ▼
                          EKS: namespace + pod + ingress
                                  │
                                  ▼
                          SNS 通知 user：你的 URL 是 {tenant}.your-domain.com
```

## Pre-sign-up Lambda

Runtime: Python 3.12

```python
import os, json, boto3

sns = boto3.client('sns')
TOPIC_ARN = os.environ['ALERTS_TOPIC_ARN']

def handler(event, context):
    email = event['request']['userAttributes'].get('email', 'unknown')
    event['response']['autoConfirmUser'] = False
    event['response']['autoVerifyEmail'] = True

    sns.publish(
        TopicArn=TOPIC_ARN,
        Subject='OpenClaw 新註冊申請',
        Message=f'有新使用者註冊：{email}\n請至 Cognito Console 審核。',
    )
    return event
```

IAM 權限：
- `sns:Publish` on `arn:aws:sns:us-west-2:{account}:OpenClawAlerts`

## Post-confirmation Lambda

Runtime: Python 3.12

核心邏輯：

```python
import os, re, secrets, json, boto3

sm = boto3.client('secretsmanager')
eks = boto3.client('eks')
sns = boto3.client('sns')
sfn = boto3.client('stepfunctions')

CLUSTER = os.environ.get('CLUSTER_NAME', 'openclaw-cluster')
ROLE_ARN = os.environ['TENANT_ROLE_ARN']
TOPIC_ARN = os.environ['ALERTS_TOPIC_ARN']
STATE_MACHINE_ARN = os.environ['STATE_MACHINE_ARN']
REGION = os.environ.get('AWS_REGION', 'us-west-2')

def sanitize_tenant(email: str) -> str:
    local = email.split('@')[0].lower()
    name = re.sub(r'[^a-z0-9-]', '-', local).strip('-')[:30]
    return name or 'user'

def handler(event, context):
    email = event['request']['userAttributes']['email']
    tenant = sanitize_tenant(email)
    namespace = f'openclaw-{tenant}'
    token = secrets.token_urlsafe(24)

    # 1. Secrets Manager
    sm.create_secret(
        Name=f'openclaw/{tenant}/gateway-token',
        SecretString=token,
        Tags=[{'Key': 'tenant-namespace', 'Value': namespace}],
    )

    # 2. 觸發 Step Functions 執行 Helm install
    sfn.start_execution(
        stateMachineArn=STATE_MACHINE_ARN,
        name=f'create-tenant-{tenant}',
        input=json.dumps({
            'tenant': tenant,
            'namespace': namespace,
            'email': email,
        }),
    )

    return event
```

### 為什麼不在 Lambda 裡直接跑 kubectl/helm？

Lambda 有 15 分鐘 timeout 且沒有 kubectl/helm binary。兩個替代方案：

| 方案 | 優點 | 缺點 |
|------|------|------|
| Step Functions → CodeBuild | 有完整 CLI 環境，可跑 create-tenant.sh | 冷啟動慢（~30s），需維護 buildspec |
| DynamoDB + In-cluster Controller | 解耦，controller 有原生 k8s 存取 | 需寫 controller，複雜度高 |

建議 Phase 1 用 Step Functions + CodeBuild，直接複用現有 `scripts/create-tenant.sh`。

IAM 權限：
- `secretsmanager:CreateSecret`
- `secretsmanager:TagResource`
- `states:StartExecution` on State Machine ARN
- `sns:Publish` on OpenClawAlerts

## 安全考量

1. Pre-sign-up 強制 `autoConfirmUser=false`，任何人都無法自行開通
2. Post-confirmation Lambda IAM 最小權限，不給 `eks:*` 或 `iam:*`，改由 Step Functions + CodeBuild 的 role 持有
3. Tenant name sanitize：只允許 `[a-z0-9-]`，最長 30 字元
4. Gateway token 用 `secrets.token_urlsafe(24)` 產生，不可預測
5. CodeBuild role 需要：`eks:CreatePodIdentityAssociation`、`secretsmanager:GetSecretValue`、`iam:PassRole`（限 OpenClawTenantRole）

## 成本

| 資源 | 預估 |
|------|------|
| Pre-sign-up Lambda | 免費層（每月幾次呼叫） |
| Post-confirmation Lambda | 免費層 |
| Step Functions | Standard workflow，每月 < 10 次 → 免費層 |
| CodeBuild | build.general1.small，每月 100 min 免費 |
| SNS | 免費層 |

月成本趨近 $0。

## 實作步驟（CDK）

### 1. 建立 SNS Topic（已存在）

現有 `OpenClawAlerts` topic 直接複用。

### 2. Pre-sign-up Lambda

```typescript
const preSignUp = new lambda.Function(this, 'PreSignUpFn', {
  runtime: lambda.Runtime.PYTHON_3_12,
  handler: 'index.handler',
  code: lambda.Code.fromAsset('lambda/pre-signup'),
  environment: { ALERTS_TOPIC_ARN: alertsTopic.topicArn },
});
alertsTopic.grantPublish(preSignUp);
```

### 3. Post-confirmation Lambda

```typescript
const postConfirm = new lambda.Function(this, 'PostConfirmFn', {
  runtime: lambda.Runtime.PYTHON_3_12,
  handler: 'index.handler',
  code: lambda.Code.fromAsset('lambda/post-confirmation'),
  environment: {
    TENANT_ROLE_ARN: tenantRole.roleArn,
    ALERTS_TOPIC_ARN: alertsTopic.topicArn,
    STATE_MACHINE_ARN: createTenantSfn.stateMachineArn,
  },
});
postConfirm.addToRolePolicy(new iam.PolicyStatement({
  actions: ['secretsmanager:CreateSecret', 'secretsmanager:TagResource'],
  resources: ['arn:aws:secretsmanager:us-west-2:*:secret:openclaw/*'],
}));
createTenantSfn.grantStartExecution(postConfirm);
```

### 4. 掛載 Lambda Trigger 到 Cognito

```typescript
const cfnUserPool = cognito.UserPool.fromUserPoolId(this, 'UserPool', 'us-west-2_yRqDzKF0t');

// 因為是 imported User Pool，需用 CfnUserPool 或 AWS CLI 掛 trigger：
// aws cognito-idp update-user-pool --user-pool-id us-west-2_yRqDzKF0t \
//   --lambda-config PreSignUp=<pre-signup-arn>,PostConfirmation=<post-confirm-arn>
```

> 注意：imported User Pool 無法用 CDK L2 直接加 trigger，需用 Custom Resource 或部署後手動 CLI 設定。

### 5. Step Functions + CodeBuild

```typescript
const createTenantProject = new codebuild.Project(this, 'CreateTenantBuild', {
  buildSpec: codebuild.BuildSpec.fromObject({
    version: '0.2',
    phases: {
      install: {
        commands: [
          'curl -LO https://dl.k8s.io/release/v1.32.0/bin/linux/arm64/kubectl && chmod +x kubectl && mv kubectl /usr/local/bin/',
          'curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash',
          'aws eks update-kubeconfig --region us-west-2 --name openclaw-cluster',
        ],
      },
      build: {
        commands: ['./scripts/create-tenant.sh "$TENANT_NAME"'],
      },
    },
  }),
  environment: { buildImage: codebuild.LinuxArmBuildImage.AMAZON_LINUX_2_STANDARD_3_0 },
  environmentVariables: {
    OPENCLAW_TENANT_ROLE_ARN: { value: tenantRole.roleArn },
  },
});
```

## 未來擴充

- 加入 Cognito Custom Message Lambda，自訂確認信內容
- 加入 quota / plan 欄位到 Cognito custom attributes
- Post-confirmation 完成後發 email 通知使用者 URL（目前先用 SNS → HC 手動通知）
- 考慮 in-cluster CRD controller 取代 CodeBuild（Phase 2）
