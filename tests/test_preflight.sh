#!/bin/bash
# =============================================================================
# Unit test: the preflight probe names the cause it found
# =============================================================================
# Needs no Docker and no network. A fake curl on PATH produces each failure the
# real one can produce, and the probe has to tell them apart.
#
# The point of the probe is that "inconclusive" is actionable (2.11). A rate
# limit, a runner with no egress and an outage on Valve's side need three
# different responses from whoever reads the verdict, so a test that only
# checked "it returns non-zero" would pass on the code this replaced.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# shellcheck source=/dev/null
source "${REPO_ROOT}/tests/preflight.sh"

failures=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; failures=$((failures + 1)); }

mkdir -p "${WORK}/bin"
PATH="${WORK}/bin:${PATH}"

# A curl that answers however the case asks. It honours the flags the probe
# actually passes: -o for the body, -D for the headers, --write-out for the
# status line, and its own exit code.
cat > "${WORK}/bin/curl" <<'FAKE'
#!/bin/bash
body=""; headers=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) body="$2"; shift 2 ;;
        -D) headers="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "${body}" ]] && printf '%s' "${FAKE_BODY:-}" > "${body}"
[[ -n "${headers}" ]] && printf '%s' "${FAKE_HEADERS:-}" > "${headers}"
printf '%s %s %s %s %s' "${FAKE_CODE:-000}" "${FAKE_EXIT:-0}" \
    "${FAKE_TOTAL:-0.100000}" "${FAKE_DNS:-0.010000}" "${FAKE_CONN:-0.020000}"
exit 0
FAKE
chmod +x "${WORK}/bin/curl"

# expect_class <class> <description> ; env vars above drive the fake
expect_class() {
    local want="$1" desc="$2" out got
    out="$(probe_url "https://example.invalid/thing" 20 "${EXPECT_SUB:-}")"
    got="${out%%:*}"
    if [[ "${got}" == "${want}" ]]; then
        pass "${desc} -> ${want}"
    else
        fail "${desc}: expected '${want}', got '${got}' (${out})"
    fi
    LAST_OUT="${out}"
}

reset() {
    FAKE_CODE=200; FAKE_EXIT=0; FAKE_BODY=""; FAKE_HEADERS=""
    FAKE_TOTAL=0.100000; FAKE_DNS=0.010000; FAKE_CONN=0.020000; EXPECT_SUB=""
    export FAKE_CODE FAKE_EXIT FAKE_BODY FAKE_HEADERS FAKE_TOTAL FAKE_DNS FAKE_CONN
}

# --- the happy path ---------------------------------------------------------
reset
expect_class ok "200 with no expected substring"
reset; FAKE_BODY='{"servertime":123}'; EXPECT_SUB="servertime"; export FAKE_BODY
expect_class ok "200 carrying the substring asked for"

# --- the one the old probe could not see ------------------------------------
reset; FAKE_CODE=429; FAKE_HEADERS=$'HTTP/1.1 429\r\nRetry-After: 120\r\n\r\n'
export FAKE_CODE FAKE_HEADERS
expect_class throttled "429 is a rate limit"
if [[ "${LAST_OUT}" == *"Retry-After 120s"* ]]; then
    pass "a 429 carries Retry-After through to the reason"
else
    fail "expected Retry-After in the reason, got: ${LAST_OUT}"
fi

# --- the far side, versus this side -----------------------------------------
reset; FAKE_CODE=503; export FAKE_CODE
expect_class server_error "503 is the far side failing, not the build"
reset; FAKE_CODE=403; export FAKE_CODE
expect_class forbidden "403 on a keyless URL means the address is blocked"
reset; FAKE_CODE=404; export FAKE_CODE
expect_class http_error "an unexpected status is not silently an outage"

# --- transport failures, which never reach a status -------------------------
reset; FAKE_EXIT=6; FAKE_CODE=000; export FAKE_EXIT FAKE_CODE
expect_class dns "curl 6 is DNS"
reset; FAKE_EXIT=7; FAKE_CODE=000; export FAKE_EXIT FAKE_CODE
expect_class refused "curl 7 is a refused connection"
reset; FAKE_EXIT=60; FAKE_CODE=000; export FAKE_EXIT FAKE_CODE
expect_class tls "curl 60 is a TLS failure"

# --- a timeout says which phase never finished ------------------------------
reset; FAKE_EXIT=28; FAKE_CODE=000; FAKE_DNS=0.000000; FAKE_CONN=0.000000
export FAKE_EXIT FAKE_CODE FAKE_DNS FAKE_CONN
expect_class timeout "curl 28 is a timeout"
[[ "${LAST_OUT}" == *"stalled at DNS"* ]] \
    && pass "a timeout with no DNS time blames DNS" \
    || fail "expected 'stalled at DNS', got: ${LAST_OUT}"

reset; FAKE_EXIT=28; FAKE_CODE=000; FAKE_DNS=0.010000; FAKE_CONN=0.000000
export FAKE_EXIT FAKE_CODE FAKE_DNS FAKE_CONN
expect_class timeout "curl 28 after DNS resolved"
[[ "${LAST_OUT}" == *"stalled at the TCP connection"* ]] \
    && pass "a timeout after DNS blames the connection" \
    || fail "expected 'stalled at the TCP connection', got: ${LAST_OUT}"

reset; FAKE_EXIT=28; FAKE_CODE=000; FAKE_DNS=0.010000; FAKE_CONN=0.020000
export FAKE_EXIT FAKE_CODE FAKE_DNS FAKE_CONN
expect_class timeout "curl 28 after the connection was made"
[[ "${LAST_OUT}" == *"stalled at the response"* ]] \
    && pass "a timeout after connecting blames the response" \
    || fail "expected 'stalled at the response', got: ${LAST_OUT}"

# --- something answering on the far side's behalf ---------------------------
reset; FAKE_BODY="<html>captive portal</html>"; EXPECT_SUB="servertime"
export FAKE_BODY
expect_class intercepted "a 200 without the expected content is not success"

# write_verdict interpolates the reason into verdict.json unquoted, and this is
# the one class whose text comes from whatever answered rather than from here.
reset; FAKE_BODY='<a href="http://portal/">hi</a> C:\path'; EXPECT_SUB="servertime"
export FAKE_BODY
expect_class intercepted "an intercepting page carrying quotes and backslashes"
case "${LAST_OUT}" in
    *'"'* | *'\'*) fail "this reason would break verdict.json: ${LAST_OUT}" ;;
    *)             pass "quotes and backslashes are stripped from the excerpt" ;;
esac

# --- a distinct class per cause, which is the whole point -------------------
reset
if [[ "$(probe_url "https://example.invalid/x" 20 | wc -l)" == "1" ]]; then
    pass "the probe prints exactly one line"
else
    fail "the probe should print one line"
fi

if [[ ${failures} -gt 0 ]]; then
    echo "${failures} check(s) failed"
    exit 1
fi
echo "All preflight checks passed"
