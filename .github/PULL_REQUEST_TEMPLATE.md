## What

Brief description of the change.

## Why

What problem does this solve? Link to issue if applicable.

## How

Key implementation details.

## Testing

- [ ] `cargo clippy -- -D warnings` passes
- [ ] `cargo test --lib` passes
- [ ] `python3 -m pytest cdk/lambda/pre-signup/test_index.py` passes
- [ ] `python3 -m pytest cdk/lambda/post-confirmation/test_index.py` passes
- [ ] `helm lint helm/charts/openclaw-platform/` passes
- [ ] `cd cdk && npx jest` passes (if CDK changes)

## Checklist

- [ ] No hardcoded secrets or credentials
- [ ] Documentation updated (if behavior changed)
- [ ] Tested on live cluster (if infra changes)
