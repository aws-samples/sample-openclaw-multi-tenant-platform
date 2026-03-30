#!/usr/bin/env bash
set -euo pipefail

# Install git hooks for this repository
HOOK_DIR="$(git rev-parse --git-dir)/hooks"
mkdir -p "$HOOK_DIR"

cat > "$HOOK_DIR/commit-msg" << 'EOF'
#!/usr/bin/env bash
# Scan commit message for sensitive data patterns
MSG_FILE="$1"
PATTERNS=(
    '[0-9]\{12\}\.dkr\.ecr'       # AWS account ID in ECR URL
    'AKIA[A-Z0-9]\{16\}'          # AWS access key
    '[a-z0-9]\{10,\}\.cloudfront\.net'  # CloudFront domain
    'arn:aws:[a-z]'               # AWS ARN
)

FOUND=0
for pat in "${PATTERNS[@]}"; do
    if grep -qE "$pat" "$MSG_FILE"; then
        echo "ERROR: Commit message contains sensitive data matching: $pat"
        FOUND=1
    fi
done

# Check for real domain names (not example.com)
if grep -qE '[a-z0-9.-]+\.(net|io|com)\b' "$MSG_FILE" | grep -v 'example\.com\|openclaw\.io\|github\.com\|kubernetes\.io\|keda\.sh\|argoproj\.io\|cncf\.io'; then
    : # complex check, skip for now
fi

if [ "$FOUND" -eq 1 ]; then
    echo "Please remove sensitive data from your commit message."
    echo "Use generic placeholders: example.com, 123456789012, etc."
    exit 1
fi
EOF
chmod +x "$HOOK_DIR/commit-msg"
echo "✅ commit-msg hook installed"
