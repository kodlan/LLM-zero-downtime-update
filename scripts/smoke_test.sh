#!/usr/bin/env bash
#
# smoke_test.sh - Smoke tests for vLLM serving endpoint
#
# Checks:
#   1. Health endpoint returns 200
#   2. Non-streaming completion returns valid response
#   3. Streaming completion receives tokens and [DONE]
#
# Usage:
#   ./scripts/smoke_test.sh [URL]
#   URL defaults to http://localhost:8000

set -euo pipefail

URL="${1:-http://localhost:8000}"
MODEL="Qwen/Qwen2.5-0.5B-Instruct"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASSED=0
FAILED=0

print_result() {
    local status="$1"
    local message="$2"
    if [[ "$status" == "ok" ]]; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        ((PASSED++))
    else
        echo -e "  ${RED}[FAIL]${NC} $message"
        ((FAILED++))
    fi
}

echo "============================================"
echo "Smoke Tests — $URL"
echo "============================================"
echo ""

# -------------------------------------------------------
# Check 1: Health endpoint
# -------------------------------------------------------
echo ">> Check 1: Health endpoint"
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$URL/health" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" == "200" ]]; then
    print_result "ok" "GET /health returned 200"
else
    print_result "fail" "GET /health returned $HTTP_CODE (expected 200)"
    if [[ "$HTTP_CODE" == "000" ]]; then
        echo ""
        echo -e "  ${RED}Cannot reach $URL. Is port-forward running?${NC}"
        echo "  Try: make port-forward"
        exit 1
    fi
fi

# -------------------------------------------------------
# Check 2: Non-streaming completion
# -------------------------------------------------------
echo ""
echo ">> Check 2: Non-streaming completion"
RESPONSE=$(curl -sf --max-time 30 -X POST "$URL/v1/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"Say hello in one word.\",\"max_tokens\":10,\"stream\":false}" \
    2>/dev/null || echo "CURL_FAILED")

if [[ "$RESPONSE" == "CURL_FAILED" ]]; then
    print_result "fail" "Non-streaming completion request failed"
else
    TEXT=$(echo "$RESPONSE" | jq -r '.choices[0].text // empty' 2>/dev/null || echo "")
    if [[ -n "$TEXT" ]]; then
        print_result "ok" "Non-streaming completion returned text"
    else
        print_result "fail" "Non-streaming completion returned empty text"
    fi
fi

# -------------------------------------------------------
# Check 3: Streaming completion
# -------------------------------------------------------
echo ""
echo ">> Check 3: Streaming completion"
STREAM_OUTPUT=$(curl -sf -N --max-time 30 -X POST "$URL/v1/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"Count from 1 to 5.\",\"max_tokens\":50,\"stream\":true}" \
    2>/dev/null || echo "CURL_FAILED")

if [[ "$STREAM_OUTPUT" == "CURL_FAILED" ]]; then
    print_result "fail" "Streaming completion request failed"
else
    DONE_SEEN=$(echo "$STREAM_OUTPUT" | grep -c "data: \[DONE\]" || true)
    DATA_LINES=$(echo "$STREAM_OUTPUT" | grep -c "^data: {" || true)
    if [[ "$DONE_SEEN" -gt 0 && "$DATA_LINES" -gt 0 ]]; then
        print_result "ok" "Streaming completion works ($DATA_LINES chunks, [DONE] received)"
    elif [[ "$DATA_LINES" -gt 0 ]]; then
        print_result "fail" "Streaming received $DATA_LINES chunks but no [DONE]"
    else
        print_result "fail" "Streaming response had no data chunks"
    fi
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "============================================"
TOTAL=$((PASSED + FAILED))
echo -e "  Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC} (out of $TOTAL)"
echo "============================================"

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi