#!/bin/bash
# identity.sh - helpers for the identity push (pcs-orchestrator doc/identity-push.md).
#
# The operator pushes this box its USER_JWT, PROVIDER_STR, UID, DOMAIN and EMAIL
# through the admin app (/api/identity/*). The box only has to ask for it: an
# empty POST to the doorbell, which the operator answers by pushing to whichever
# PCS owns the caller's IP. Nothing here needs a credential, which is what lets
# a box that lost every env file recover.
#
# Source it; it defines functions only.

_identity_b64url_decode() {
    local s="${1//-/+}"
    s="${s//_//}"
    case $(( ${#s} % 4 )) in
        2) s="$s==" ;;
        3) s="$s=" ;;
    esac
    printf '%s' "$s" | base64 -d 2>/dev/null
}

# Algorithm of a JWT, from its header. RS256 = pushed, HS256 = the legacy pulled token.
jwt_alg() {
    _identity_b64url_decode "${1%%.*}" | grep -o '"alg":"[^"]*"' | head -n1 | cut -d'"' -f4
}

# `exp` of a JWT, in epoch seconds; empty when absent or unreadable.
jwt_exp() {
    local payload="${1#*.}"
    payload="${payload%%.*}"
    _identity_b64url_decode "$payload" | grep -o '"exp":[0-9]*' | head -n1 | cut -d: -f2
}

# True when TOKEN is a pushed (RS256) USER_JWT with more than MIN_SECONDS left.
# The operator refreshes at 3 days left, so the default 2 days only trips when
# the refresh has been failing.
identity_token_fresh() {
    local token="$1" min="${2:-172800}" exp
    [ -n "$token" ] || return 1
    [ "$(jwt_alg "$token")" = "RS256" ] || return 1
    exp=$(jwt_exp "$token") || true
    [ -n "$exp" ] || return 1
    [ "$exp" -gt $(( $(date +%s) + min )) ]
}

# Ask the operator to push this box its identity. The operator always answers
# 204, whether or not it recognised the caller, so success only means "rang".
identity_ring_doorbell() {
    local api="${1%/}" code
    code=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -X POST "$api/identity/doorbell" 2>/dev/null) || code="000"
    [ "$code" = "204" ]
}
