#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf -- "$temporary"' EXIT
mkdir "$temporary/bin"
cat >"$temporary/bin/az" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$MOCK_CALLS"
case "$1 $2" in
    "group exists")
        if [[ "${MOCK_MODE:-}" == expired-login ]]; then echo "fixture-auth-expired" >&2; exit 1; fi
        if [[ "${MOCK_MODE:-}" == orphan && "$*" == *MC_fixture-demo_cpu-demo* ]]; then echo true; exit; fi
        [[ "${MOCK_MODE:-}" == unsafe-tag ]] && echo true || echo false ;;
    "group show") echo '{"tags":{"sample":"not-this-sample"}}' ;;
    "account show")
        [[ "$*" == *"--query tenantId"* ]] && echo fixture-tenant || echo fixture-subscription ;;
    "rest --method")
        if [[ "${MOCK_MODE:-}" == deny ]]; then
            echo '{"value":[{"actions":["*"],"notActions":["Microsoft.Authorization/*/Write"]}]}'
        else
            echo '{"value":[{"actions":["Microsoft.Authorization/roleAssignments/*"],"notActions":["Microsoft.Authorization/roleDefinitions/write"]}]}'
        fi ;;
    "provider show") echo Registered ;;
    "feature show")
        if [[ "${MOCK_MODE:-}" == missing-preview && "$*" == *ApplicationLoadBalancerPreview* ]]; then
            echo NotRegistered
        else echo Registered; fi ;;
    "ad signed-in-user") echo fixture-principal ;;
    *) echo "Unexpected Azure operation in read-only test" >&2; exit 99 ;;
esac
MOCK
chmod +x "$temporary/bin/az"
for tool in kubectl kubelogin; do
    printf '#!/usr/bin/env bash\nexit 99\n' >"$temporary/bin/$tool"
    chmod +x "$temporary/bin/$tool"
done
export PATH="$temporary/bin:$PATH" MOCK_CALLS="$temporary/calls"
export SUBSCRIPTION=fixture-subscription RESOURCE_GROUP=fixture-demo REGISTRY=fixtureregistry KUBERNETES_VERSION=1.36.5
expect_failure() {
    if "$@" >"$temporary/stdout" 2>"$temporary/stderr"; then
        echo "Expected failure did not occur." >&2; exit 1
    fi
}
export MOCK_MODE=deny
expect_failure bash "$ROOT/scripts/deploy.sh" --preflight-only
grep -q 'no advertised roleAssignments/write' "$temporary/stderr"
export MOCK_MODE=allow
bash "$ROOT/scripts/deploy.sh" --preflight-only >"$temporary/stdout"
grep -q 'No resources created' "$temporary/stdout"
expect_failure bash "$ROOT/scripts/deploy.sh"
export MOCK_MODE=missing-preview
expect_failure bash "$ROOT/scripts/deploy.sh" --preflight-only
grep -q 'ApplicationLoadBalancerPreview' "$temporary/stderr"
export MOCK_MODE=unsafe-tag
expect_failure bash "$ROOT/scripts/cleanup.sh" --confirm-delete
grep -q 'Safety tag mismatch' "$temporary/stderr"
export MOCK_MODE=expired-login
expect_failure bash "$ROOT/scripts/deploy.sh" --preflight-only
grep -q 'fixture-auth-expired' "$temporary/stderr"
if grep -q 'Refusing to reuse' "$temporary/stderr"; then
    echo "Azure authentication failure was incorrectly treated as group existence." >&2; exit 1
fi
expect_failure bash "$ROOT/scripts/cleanup.sh" --confirm-delete
grep -q 'fixture-auth-expired' "$temporary/stderr"
export MOCK_MODE=orphan
expect_failure bash "$ROOT/scripts/cleanup.sh" --confirm-delete
grep -q 'managed group remains' "$temporary/stderr"
if grep -Eq '(^| )(create|delete|register)( |$)' "$MOCK_CALLS"; then
    echo "A mutating Azure operation was attempted in a read-only/safety fixture." >&2; exit 1
fi
echo "Bash safety fixtures passed: permission exclusions, read-only preflight, cost/preview guards, authentication failures and scoped cleanup."
