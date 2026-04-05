## What

Brief description of the change.

## Why

What problem does this solve? Link to issue if applicable.

## How

Key implementation details.

## Testing

- [ ] `cd cdk && npx tsc --noEmit` passes (if CDK changes)
- [ ] `cd cdk && npx jest` passes (if CDK changes)
- [ ] `helm lint helm/charts/openclaw-platform/` passes (if Helm changes)
- [ ] `bash -n scripts/*.sh` passes (if script changes)
- [ ] `python3 -m py_compile cdk/lambda/*/index.py` passes (if Lambda changes)

## Checklist

- [ ] No hardcoded secrets or credentials
- [ ] Documentation updated (if behavior changed)
- [ ] Tested on live cluster (if infra changes)
