# Dynamic Stack Naming Design

## Problem Statement

Current hardcoded stack name "OpenClawEksStack" causes deployment conflicts:
- Cannot deploy while previous stack is DELETE_IN_PROGRESS
- Blocks parallel deployments in same region
- Forces users to wait for complete cleanup before redeployment

## Proposed Solution

### Option A: Timestamp-Based Naming (Recommended)
```typescript
// cdk/bin/cdk.ts
const timestamp = process.env.CDK_STACK_SUFFIX || new Date().toISOString()
  .replace(/[:.]/g, '-')
  .slice(0, 19); // 2026-04-11T22-50-15

const stackName = `OpenClawEksStack-${timestamp}`;
```

**Benefits:**
- ✅ Chronological ordering  
- ✅ Human readable
- ✅ Deterministic for same deployment session
- ✅ Avoids conflicts

**Stack Examples:**
- `OpenClawEksStack-2026-04-11T22-50-15`
- `OpenClawEksStack-2026-04-12T08-30-42`

### Option B: Git-Based Naming
```typescript
const gitHash = process.env.CDK_STACK_SUFFIX || 
  require('child_process').execSync('git rev-parse --short HEAD').toString().trim();

const stackName = `OpenClawEksStack-${gitHash}`;
```

**Benefits:**
- ✅ Links to source code version
- ✅ Reproducible builds
- ✅ Developer friendly

**Limitations:**
- ❌ Same hash = same conflict (if not cleaned up)
- ❌ Requires git repo

### Option C: Hybrid Approach (Best of Both)
```typescript
const defaultSuffix = () => {
  try {
    const gitHash = require('child_process')
      .execSync('git rev-parse --short HEAD', {stdio: 'pipe'})
      .toString().trim();
    const timestamp = new Date().toISOString().slice(11, 19).replace(/:/g, '');
    return `${gitHash}-${timestamp}`;
  } catch {
    return new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  }
};

const stackName = `OpenClawEksStack-${process.env.CDK_STACK_SUFFIX || defaultSuffix()}`;
```

**Examples:**
- `OpenClawEksStack-a1b2c3d-225015` (git + time)
- `OpenClawEksStack-2026-04-11T22-50-15` (fallback)

## Implementation Changes Required

### 1. CDK Changes (Low Impact)

**File: `cdk/bin/cdk.ts`**
```typescript
// Current
new EksClusterStack(app, 'OpenClawEksStack', {

// New  
const stackName = generateStackName();
new EksClusterStack(app, stackName, {
```

### 2. Script Changes (Medium Impact)

**Strategy: Environment Variable Pattern**
```bash
# All scripts will use:
STACK_NAME="${CDK_STACK_NAME:-$(get_deployed_stack_name)}"

# Where get_deployed_stack_name() discovers the actual deployed stack
get_deployed_stack_name() {
  aws cloudformation list-stacks --region "$REGION" \
    --query 'StackSummaries[?starts_with(StackName,`OpenClawEksStack-`) && StackStatus!=`DELETE_COMPLETE`].StackName' \
    --output text | head -1
}
```

**File: `scripts/lib/common.sh`** (Update base functions)
```bash
# Current
STACK="${STACK:-OpenClawEksStack}"

# New
discover_stack_name() {
  # 1. Use explicit override
  if [[ -n "${CDK_STACK_NAME:-}" ]]; then
    echo "$CDK_STACK_NAME"
    return
  fi
  
  # 2. Discover from active deployments
  local active_stack
  active_stack=$(aws cloudformation list-stacks --region "$REGION" \
    --query 'StackSummaries[?starts_with(StackName,`OpenClawEksStack-`) && StackStatus!=`DELETE_COMPLETE`].StackName' \
    --output text | head -1)
  
  if [[ -n "$active_stack" && "$active_stack" != "None" ]]; then
    echo "$active_stack"
    return
  fi
  
  # 3. Fallback to legacy name
  echo "OpenClawEksStack"
}

STACK="${STACK:-$(discover_stack_name)}"
```

### 3. Deployment Flow Changes

**File: `setup.sh`**
```bash
# Generate and export stack name for consistency
export CDK_STACK_SUFFIX="${CDK_STACK_SUFFIX:-$(date +%Y-%m-%dT%H-%M-%S)}"
export CDK_STACK_NAME="OpenClawEksStack-${CDK_STACK_SUFFIX}"

echo "Deploying stack: $CDK_STACK_NAME"
```

## Benefits Analysis

### ✅ Immediate Benefits

1. **Eliminates Deployment Conflicts**
   - No more waiting for DELETE_IN_PROGRESS
   - Support parallel deployments
   - Faster iteration cycles

2. **Better Version Management**
   - Each deployment has unique identifier
   - Easy to track which version is deployed
   - Supports blue-green style deployments

3. **Improved Testing**
   - Multiple test environments in same region
   - Isolated CI/CD pipelines
   - No cross-contamination

### ✅ Operational Benefits

1. **Easier Cleanup**
   ```bash
   # Clean specific version
   ./force-cleanup.sh --stack OpenClawEksStack-2026-04-11T22-50-15
   
   # Clean all versions
   ./force-cleanup.sh --all-openclaw-stacks
   ```

2. **Better Debugging**
   - Clear deployment history
   - Version-specific resource naming
   - Easier correlation with logs

3. **Enhanced Security**
   - Time-limited stack names reduce long-term exposure
   - Clear audit trail
   - No accidental reuse of old configurations

## Side Effects & Risks Analysis

### ⚠️ Potential Issues

1. **Resource Discovery Complexity**
   ```bash
   # Old: Simple reference  
   aws cloudformation describe-stacks --stack-name OpenClawEksStack
   
   # New: Dynamic discovery required
   STACK_NAME=$(discover_stack_name)
   aws cloudformation describe-stacks --stack-name "$STACK_NAME"
   ```

2. **Documentation Updates**
   - All documentation referencing stack name needs updating
   - Examples become more complex
   - User confusion about which stack to use

3. **Backward Compatibility**
   - Existing deployments use old naming
   - Migration path needed
   - Scripts must handle both patterns

### 🛡️ Mitigation Strategies

1. **Graceful Migration**
   ```bash
   # Support both old and new naming patterns
   get_stack_name() {
     # Try new pattern first
     local new_stack
     new_stack=$(aws cloudformation list-stacks --region "$REGION" \
       --query 'StackSummaries[?starts_with(StackName,`OpenClawEksStack-`)].StackName' \
       --output text | head -1)
     
     if [[ -n "$new_stack" && "$new_stack" != "None" ]]; then
       echo "$new_stack"
       return
     fi
     
     # Fallback to legacy pattern
     echo "OpenClawEksStack"
   }
   ```

2. **Clear User Communication**
   ```bash
   echo "📋 Deploying stack: $CDK_STACK_NAME"
   echo "💡 To reference this deployment later:"
   echo "   export CDK_STACK_NAME=$CDK_STACK_NAME"
   ```

3. **Environment File Support**
   ```bash
   # Save deployment info
   echo "CDK_STACK_NAME=$CDK_STACK_NAME" > .openclaw-deployment
   echo "REGION=$REGION" >> .openclaw-deployment
   
   # Scripts can source this file
   [[ -f .openclaw-deployment ]] && source .openclaw-deployment
   ```

## Implementation Priority

### Phase 1: Core Changes (1-2 days)
- [x] Update CDK entry point with dynamic naming
- [x] Update common.sh with discovery logic  
- [x] Update key scripts (setup.sh, deploy-platform.sh)
- [x] Add backward compatibility layer

### Phase 2: Script Updates (2-3 days)  
- [x] Update all remaining scripts
- [x] Add environment file support
- [x] Update documentation and examples
- [x] Add migration guide

### Phase 3: Enhanced Features (1 week)
- [ ] Stack management commands (`list-stacks`, `cleanup-old-stacks`)
- [ ] Advanced discovery logic
- [ ] Integration with GitHub Actions
- [ ] Automated old stack cleanup

## Conclusion

**Recommendation: Implement Option C (Hybrid Approach)**

This solves the immediate deployment conflict issue while providing the best long-term benefits. The implementation requires careful attention to backward compatibility but provides significant operational improvements.

**Key Success Metrics:**
- ✅ Zero deployment conflicts due to stack naming
- ✅ <30 second setup time for new deployments  
- ✅ 100% backward compatibility with existing deployments
- ✅ Clear user experience with proper messaging