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
        if [[ "${MOCK_MODE:-}" == wrong-context && "$*" != *"--subscription"* ]]; then
            echo '{"id":"other-subscription","tenantId":"other-tenant","user":{"name":"other-user"}}'
        else
            echo '{"id":"fixture-subscription","tenantId":"fixture-tenant","user":{"name":"fixture-user"}}'
        fi ;;
    "account get-access-token")
        if [[ "${MOCK_MODE:-}" == expired-login ]]; then echo "fixture-auth-expired" >&2; exit 1; fi
        echo fixture-tenant ;;
    "rest --method")
        if [[ "${MOCK_MODE:-}" == deny ]]; then
            echo '{"value":[{"actions":["*"],"notActions":["Microsoft.Authorization/*/Write"]}]}'
        elif [[ "${MOCK_MODE:-}" == paginated || "${MOCK_MODE:-}" == page-failure ]]; then
            if [[ "$*" == *"skiptoken=second"* ]]; then
                if [[ "$MOCK_MODE" == page-failure ]]; then echo "fixture-page-read-failed" >&2; exit 1; fi
                echo '{"value":[{"actions":["MICROSOFT.AUTHORIZATION/*"],"notActions":[]}]}'
            else
                echo '{"value":[{"actions":["*"],"notActions":["Microsoft.Authorization/*/Write"]}],"nextLink":"https://management.azure.com/subscriptions/fixture-subscription/providers/Microsoft.Authorization/permissions?api-version=2022-04-01&skiptoken=second"}'
            fi
        elif [[ "${MOCK_MODE:-}" == malformed-permissions ]]; then
            echo '{"value":[{"actions":"*","notActions":[]}]}'
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
grep -q 'NOT a demonstrated Azure authorization denial' "$temporary/stderr"
export MOCK_MODE=allow
bash "$ROOT/scripts/deploy.sh" --preflight-only >"$temporary/stdout"
grep -q 'No resources created' "$temporary/stdout"
export MOCK_MODE=paginated
bash "$ROOT/scripts/deploy.sh" --preflight-only >"$temporary/stdout"
grep -q 'No resources created' "$temporary/stdout"
grep -q 'skiptoken=second' "$MOCK_CALLS"
export MOCK_MODE=page-failure
expect_failure bash "$ROOT/scripts/deploy.sh" --preflight-only
grep -q 'fixture-page-read-failed' "$temporary/stderr"
if grep -q 'Preflight did not establish roleAssignments/write' "$temporary/stderr"; then
    echo "An incomplete permission read was incorrectly treated as negative permission evidence." >&2; exit 1
fi
export MOCK_MODE=malformed-permissions
expect_failure bash "$ROOT/scripts/deploy.sh" --preflight-only
grep -q 'evidence is incomplete' "$temporary/stderr"
export MOCK_MODE=wrong-context
expect_failure bash "$ROOT/scripts/deploy.sh" --preflight-only
grep -q 'THIS Linux terminal' "$temporary/stderr"
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
