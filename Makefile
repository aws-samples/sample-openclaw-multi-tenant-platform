.PHONY: lint test validate check-cdk check-helm check-python check-rust check-sensitive check-cjk check-shell check-deny check-cdk-test test-operator test-lambda

# --- Aggregates ---
lint: check-cdk check-cdk-test check-helm check-python check-rust check-deny check-shell check-sensitive check-cjk

test: test-operator check-cdk-test test-lambda

validate: lint test

check-cdk:
	cd cdk && npm ci && npx tsc --noEmit

check-cdk-test:
	cd cdk && npx jest --passWithNoTests

check-helm:
	helm lint helm/charts/openclaw-platform

check-python:
	python3 -m py_compile cdk/lambda/pre-signup/index.py
	python3 -m py_compile cdk/lambda/post-confirmation/index.py
	python3 -m py_compile cdk/lambda/cost-enforcer/index.py

check-rust:
	cd operator && cargo clippy --all-targets --all-features -- -D warnings

check-deny:
	cd operator && cargo deny check 2>/dev/null || echo "Install cargo-deny: cargo install cargo-deny"

check-shell:
	-shellcheck scripts/*.sh

check-sensitive:
	@FOUND=$$(grep -rn '387671391109\|AKIA' --include='*.ts' --include='*.py' --include='*.md' --include='*.sh' . | grep -v node_modules | grep -v cdk.out | grep -v cdk.json || true); \
	if [ -n "$$FOUND" ]; then echo "$$FOUND"; exit 1; fi; \
	echo "Clean"

check-cjk:
	@python3 -c "\
	import glob; found=[]; \
	[found.extend(f'{f}:{i}' for i,l in enumerate(open(f),1) if any('\u4e00'<=c<='\u9fff' for c in l)) \
	 for ext in ['*.ts','*.py','*.rs','*.html'] \
	 for f in glob.glob(f'**/{ext}',recursive=True) \
	 if not any(x in f for x in ['node_modules','cdk.out','.git','target/'])]; \
	exit(1) if found and [print(f'CJK found in {len(found)} lines:')] and [print(f'  {f}') for f in found[:10]] else print('Clean')"

test-operator:
	cd operator && cargo test --lib

test-lambda:
	python3 -m pytest cdk/lambda/pre-signup/test_index.py -v
	python3 -m pytest cdk/lambda/post-confirmation/test_index.py -v
