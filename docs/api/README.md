# 🚀 OpenClaw Platform API Documentation

## 📋 Overview

OpenClaw Platform provides multiple API layers for different use cases:

- **Authentication API**: Amazon Cognito-based user authentication
- **Gateway API**: Tenant-specific AI assistant interactions  
- **Admin API**: Platform management and operations
- **Webhook API**: Event notifications and integrations

## 🔐 Authentication Flow

### 1. User Sign Up/Sign In
```javascript
// Direct Cognito API calls (no Hosted UI)
const response = await fetch(`https://cognito-idp.${region}.amazonaws.com/`, {
  method: 'POST',
  headers: {
    'Content-Type': 'application/x-amz-json-1.1',
    'X-Amz-Target': 'AWSCognitoIdentityProviderService.SignUp'
  },
  body: JSON.stringify({
    ClientId: 'your-client-id',
    Username: 'user@example.com',
    Password: 'SecurePass123!',
    UserAttributes: [{Name: 'email', Value: 'user@example.com'}]
  })
});
```

### 2. Gateway Token Extraction
```javascript
// Extract gateway token from ID token
function getGatewayToken(idToken) {
  const decoded = decodeJwt(idToken);
  return decoded['custom:gateway_token'] || '';
}
```

## 🎯 Gateway API

### Base URL Pattern
```
https://{domain}/t/{tenant}/
```

### Authentication
```bash
# Token-based authentication
curl -H "Authorization: Bearer ${GATEWAY_TOKEN}" \
     "https://example.com/t/alice/api/chat"
```

### Chat Endpoints
```typescript
// POST /api/chat - Send message to AI assistant
interface ChatRequest {
  message: string;
  conversation_id?: string;
  model?: 'claude-3-sonnet' | 'claude-3-haiku';
}

interface ChatResponse {
  response: string;
  conversation_id: string;
  usage: {
    input_tokens: number;
    output_tokens: number;
  }
}
```

## 🔧 Admin API

### Tenant Management
```bash
# List all tenants
kubectl get applicationset openclaw-tenants -n argocd \
  -o jsonpath='{.spec.generators[0].list.elements[*].name}'

# Create tenant (bypasses Cognito)
./scripts/create-tenant.sh alice --email alice@example.com

# Delete tenant
./scripts/delete-tenant.sh alice --force
```

### Health Check
```bash
# Platform health
./scripts/health-check.sh

# Tenant-specific health  
curl https://example.com/t/alice/health
```

## 📡 Webhook API

### Event Types
```typescript
interface TenantCreatedEvent {
  event_type: 'tenant.created';
  tenant_name: string;
  user_email: string;
  created_at: string;
}

interface TenantDeletedEvent {
  event_type: 'tenant.deleted';  
  tenant_name: string;
  deleted_at: string;
}
```

### Webhook Configuration
```bash
# Configure SNS topic for notifications
aws sns create-topic --name openclaw-events
aws sns subscribe --topic-arn arn:aws:sns:region:account:openclaw-events \
  --protocol https --notification-endpoint https://your-webhook.com/openclaw
```

## ⚡ Rate Limits

### Authentication API
- Sign Up: 5 requests/minute per IP
- Sign In: 10 requests/minute per user
- Password Reset: 3 requests/hour per user

### Gateway API  
- Chat Messages: 100 requests/minute per tenant
- File Upload: 10 requests/minute per tenant
- Model Access: Based on AWS Bedrock quotas

## 🔍 Error Handling

### Common Error Codes
```typescript
interface ErrorResponse {
  error: {
    code: string;
    message: string;
    details?: any;
  }
}

// Authentication Errors
'NotAuthorizedException' // Invalid credentials
'UserNotConfirmedException' // Email not verified
'InvalidParameterException' // Invalid request format

// Gateway Errors  
'InvalidToken' // Expired or invalid gateway token
'TenantNotFound' // Tenant workspace not ready
'RateLimitExceeded' // Too many requests
```

### Retry Strategy
```javascript
// Exponential backoff for transient errors
async function retryWithBackoff(fn, maxRetries = 3) {
  for (let i = 0; i < maxRetries; i++) {
    try {
      return await fn();
    } catch (error) {
      if (i === maxRetries - 1) throw error;
      
      const delay = Math.min(1000 * Math.pow(2, i), 10000);
      await new Promise(resolve => setTimeout(resolve, delay));
    }
  }
}
```

## 📖 Related Documentation

- [Authentication Guide](authentication.md) - Detailed auth flow
- [Gateway API Reference](gateway-api.md) - Complete endpoint documentation  
- [Admin Operations](admin-operations.md) - Management API
- [Webhooks](webhooks.md) - Event handling and integrations
- [Rate Limiting](rate-limiting.md) - Quotas and throttling

## 🚨 Production Considerations

### Security
- Always use HTTPS in production
- Validate JWT tokens server-side
- Implement proper CORS policies
- Monitor for suspicious activity

### Performance
- Cache gateway tokens appropriately
- Implement client-side retry logic
- Use connection pooling for high volume
- Monitor API latency and error rates

### Monitoring  
- Set up CloudWatch alarms for error rates
- Track authentication success/failure metrics
- Monitor tenant resource usage
- Alert on API quota approaching limits