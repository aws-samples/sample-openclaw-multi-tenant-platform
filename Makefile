.PHONY: lint check-cdk check-helm check-python check-rust check-sensitive check-cjk check-shell

lint: check-cdk check-helm check-python check-rust check-shell check-sensitive check-cjk

check-cdk:
	cd cdk && npm ci && npx tsc --noEmit

check-helm:
	helm lint helm/charts/openclaw-platform

check-python:
	python3 -m py_compile cdk/lambda/pre-signup/index.py
	python3 -m py_compile cdk/lambda/post-confirmation/index.py

check-rust:
	cd operator && cargo check

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
