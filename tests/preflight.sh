#!/bin/bash
# =============================================================================
# Preflight probe - say which precondition failed, not just that one did
# =============================================================================
# A library, not a test. Sourced by tests/run_e2e.sh and exercised by
# tests/test_preflight.sh.
#
# The probe this replaces was:
#
#     curl -sf -m 20 -o /dev/null https://api.steampowered.com/...
#
# and it had two problems.
#
# It asked the wrong service. Nothing in this suite calls Steam's web API: the
# image pulls SteamCMD from steamcdn-a.akamaihd.net, the app comes from Steam's
# content servers, the discoverable rung is a direct A2S_INFO datagram to the
# container, and the build id is read out of the local appmanifest. A web API
# hiccup marked runs inconclusive that would have passed.
#
# And `-f` with `-o /dev/null` destroyed the evidence. `-f` turns every status
# from 400 up into one curl exit, and nothing kept the status code, so a DNS
# failure, a stalled connection, a rate limit and an outage on the far side all
# arrived as the same sentence. An inconclusive verdict is only actionable if
# it names its cause (2.11), and a run that cannot say why it could not look is
# the shape clause 2.8 exists to forbid.
#
# So: keep the status code, keep curl's exit code, and keep the phase timings,
# because they are what lets a timeout say where it stalled.

# What the run actually needs before it can prove anything. This is the exact
# URL the Dockerfile fetches, so it is a precondition and not a stand-in for
# one. Overridable so the test can point it at a local fixture.
STEAMCMD_INSTALLER_URL="${STEAMCMD_INSTALLER_URL:-https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz}"

# probe_url <url> [timeout_seconds] [expect_substring]
#
# Prints "<class>: <detail>" and returns 0 only for class "ok".
# Classes: ok throttled forbidden server_error dns refused timeout tls
#          intercepted http_error no_curl
probe_url() {
    local url="$1" timeout="${2:-20}" expect="${3:-}"
    local body headers out code exit_code t_total t_dns t_conn
    local retry where result rc=1

    if ! command -v curl >/dev/null 2>&1; then
        echo "no_curl: curl is not installed, so this could not be checked"
        return 1
    fi

    body="$(mktemp)"
    headers="$(mktemp)"

    # No -f: it collapses every 4xx and 5xx into a single exit code and throws
    # away the status, which is the most useful thing the far side said.
    out="$(curl -sS -m "${timeout}" -L \
        -o "${body}" -D "${headers}" \
        --write-out '%{http_code} %{exitcode} %{time_total} %{time_namelookup} %{time_connect}' \
        "${url}" 2>/dev/null)"
    read -r code exit_code t_total t_dns t_conn <<<"${out:-000 99 0 0 0}"

    retry="$(awk 'BEGIN { IGNORECASE = 1 } /^retry-after:/ { gsub(/\r/, ""); print $2 }' "${headers}" | tail -1)"

    if [[ "${exit_code}" != "0" ]]; then
        case "${exit_code}" in
            6) result="dns: ${url} did not resolve: the runner has no DNS or no egress" ;;
            7) result="refused: ${url} resolved but refused the connection" ;;
            28)
                # Which phase never finished separates DNS from a black hole
                # from a server that accepted and then went quiet.
                where="the response"
                if [[ "${t_conn}" == "0.000000" ]]; then
                    where="the TCP connection"
                    [[ "${t_dns}" == "0.000000" ]] && where="DNS"
                fi
                result="timeout: ${url} did not answer within ${timeout}s, stalled at ${where}" ;;
            35|58|60|77)
                result="tls: the TLS handshake with ${url} failed (curl ${exit_code}): interception, a proxy, or a skewed clock" ;;
            *) result="http_error: curl exited ${exit_code} for ${url}" ;;
        esac
    else
        case "${code}" in
            200|206)
                if [[ -n "${expect}" ]] && ! grep -q "${expect}" "${body}"; then
                    # This reason is interpolated into verdict.json unquoted,
                    # and the excerpt is whatever answered - usually HTML. Drop
                    # the two characters that would end the JSON string early.
                    local excerpt
                    excerpt="$(head -c 80 "${body}" | tr -d '\r\n"\\')"
                    result="intercepted: ${url} returned ${code} without '${expect}': ${excerpt}"
                else
                    result="ok: ${url} answered ${code} in ${t_total}s"
                    rc=0
                fi ;;
            429)
                result="throttled: ${url} rate-limited this runner's address (429)${retry:+; Retry-After ${retry}s}" ;;
            401|403)
                result="forbidden: ${url} answered ${code}; it needs no credentials, so the source address is blocked" ;;
            500|502|503|504)
                result="server_error: ${url} answered ${code}, which is the far side failing${retry:+; Retry-After ${retry}s}" ;;
            *)
                result="http_error: ${url} answered ${code}" ;;
        esac
    fi

    rm -f "${body}" "${headers}"
    echo "${result}"
    return "${rc}"
}
