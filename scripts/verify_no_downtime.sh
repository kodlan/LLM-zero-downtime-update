#!/usr/bin/env bash
#
# verify_no_downtime.sh - Run streaming load and verify no-downtime criteria
#
# Phases:
#   1. Pre-flight health check
#   2. Run smoke tests
#   3. Run streaming load test
#   4. Validate acceptance criteria from results
#
# Usage:
#   ./scripts/verify_no_downtime.sh [URL]
#
# Environment variables:
#   CONCURRENCY       - concurrent workers (default: 4)
#   DURATION          - test duration in seconds (default: 30)
#   MAX_TOKENS        - max tokens per request (default: 100)
#   MAX_ERROR_RATE    - max allowed error rate (default: 0.05)
#   MAX_5XX_RATE      - max allowed 5xx rate (default: 0.02)
#   MIN_STREAM_COMPLETION - min stream completion rate (default: 0.90)
#
# Exit codes:
#   0 - All acceptance criteria passed
#   1 - One or more criteria failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

URL="${1:-http://localhost:8000}"
CONCURRENCY="${CONCURRENCY:-4}"
DURATION="${DURATION:-30}"
MAX_TOKENS="${MAX_TOKENS:-100}"
RESULTS_FILE="/tmp/stream_load_results.json"

# Acceptance thresholds
MAX_ERROR_RATE="${MAX_ERROR_RATE:-0.05}"
MAX_5XX_RATE="${MAX_5XX_RATE:-0.02}"
MIN_STREAM_COMPLETION="${MIN_STREAM_COMPLETION:-0.90}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

CHECKS_PASSED=0
CHECKS_FAILED=0

check_result() {
    local status="$1"
    local message="$2"
    if [[ "$status" == "ok" ]]; then
        echo -e "  ${GREEN}[PASS]${NC} $message"
        CHECKS_PASSED=$((CHECKS_PASSED + 1))
    else
        echo -e "  ${RED}[FAIL]${NC} $message"
        CHECKS_FAILED=$((CHECKS_FAILED + 1))
    fi
}

echo "============================================"
echo "No-Downtime Verification"
echo "============================================"
echo ""
echo "  URL:                $URL"
echo "  Concurrency:        $CONCURRENCY"
echo "  Duration:           ${DURATION}s"
echo "  Max error rate:     $MAX_ERROR_RATE"
echo "  Max 5xx rate:       $MAX_5XX_RATE"
echo "  Min stream compl:   $MIN_STREAM_COMPLETION"
echo ""

# -------------------------------------------------------
# Phase 1: Pre-flight
# -------------------------------------------------------
echo ">> Phase 1: Pre-flight health check"
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" "$URL/health" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "200" ]]; then
    log_error "Cannot reach $URL/health (got $HTTP_CODE)."
    echo "  Is port-forward running? Try: make port-forward"
    exit 1
fi
log_info "Endpoint healthy."
echo ""

# -------------------------------------------------------
# Phase 2: Smoke tests
# -------------------------------------------------------
echo ">> Phase 2: Smoke tests"
if ! "$SCRIPT_DIR/smoke_test.sh" "$URL"; then
    log_error "Smoke tests failed. Aborting verification."
    exit 1
fi
echo ""

# -------------------------------------------------------
# Phase 3: Streaming load test
# -------------------------------------------------------
echo ">> Phase 3: Streaming load test"
log_info "Running load test: concurrency=$CONCURRENCY, duration=${DURATION}s"
echo ""

python3 "$PROJECT_ROOT/load/stream_load.py" \
    --url "$URL" \
    --concurrency "$CONCURRENCY" \
    --duration "$DURATION" \
    --max-tokens "$MAX_TOKENS" \
    --prompts-file "$PROJECT_ROOT/load/scenarios/short_prompts.txt" \
    --output "$RESULTS_FILE"

if [[ ! -f "$RESULTS_FILE" ]]; then
    log_error "Results file not found: $RESULTS_FILE"
    exit 1
fi
echo ""

# -------------------------------------------------------
# Phase 4: Validate acceptance criteria
# -------------------------------------------------------
echo ">> Phase 4: Acceptance criteria validation"
echo ""

ERROR_RATE=$(jq -r '.metrics.error_rate' "$RESULTS_FILE")
STREAM_COMPLETION=$(jq -r '.metrics.stream_completion_rate' "$RESULTS_FILE")
TOTAL_REQUESTS=$(jq -r '.metrics.total_requests' "$RESULTS_FILE")
SUCCESSFUL=$(jq -r '.metrics.successful' "$RESULTS_FILE")
FAILED=$(jq -r '.metrics.failed' "$RESULTS_FILE")

# Compute 5xx rate from status_code_counts
TOTAL_5XX=$(jq -r '[.metrics.status_code_counts | to_entries[] | select(.key | test("^5")) | .value] | add // 0' "$RESULTS_FILE")
if [[ "$TOTAL_REQUESTS" -gt 0 ]]; then
    RATE_5XX=$(echo "scale=4; $TOTAL_5XX / $TOTAL_REQUESTS" | bc)
else
    RATE_5XX="0"
fi

echo "  Measured values:"
echo "    Total requests:       $TOTAL_REQUESTS"
echo "    Successful:           $SUCCESSFUL"
echo "    Failed:               $FAILED"
echo "    Error rate:           $ERROR_RATE"
echo "    5xx rate:             $RATE_5XX"
echo "    Stream completion:    $STREAM_COMPLETION"
echo ""

# Check 1: Error rate
if (( $(echo "$ERROR_RATE <= $MAX_ERROR_RATE" | bc -l) )); then
    check_result "ok" "Error rate $ERROR_RATE <= $MAX_ERROR_RATE"
else
    check_result "fail" "Error rate $ERROR_RATE > $MAX_ERROR_RATE"
fi

# Check 2: 5xx rate
if (( $(echo "$RATE_5XX <= $MAX_5XX_RATE" | bc -l) )); then
    check_result "ok" "5xx rate $RATE_5XX <= $MAX_5XX_RATE"
else
    check_result "fail" "5xx rate $RATE_5XX > $MAX_5XX_RATE"
fi

# Check 3: Stream completion rate
if (( $(echo "$STREAM_COMPLETION >= $MIN_STREAM_COMPLETION" | bc -l) )); then
    check_result "ok" "Stream completion $STREAM_COMPLETION >= $MIN_STREAM_COMPLETION"
else
    check_result "fail" "Stream completion $STREAM_COMPLETION < $MIN_STREAM_COMPLETION"
fi

# -------------------------------------------------------
# Summary
# -------------------------------------------------------
echo ""
echo "============================================"
TOTAL_CHECKS=$((CHECKS_PASSED + CHECKS_FAILED))
echo -e "  Checks: ${GREEN}$CHECKS_PASSED passed${NC}, ${RED}$CHECKS_FAILED failed${NC} (out of $TOTAL_CHECKS)"
echo "  Results file: $RESULTS_FILE"
echo "============================================"

if [[ "$CHECKS_FAILED" -gt 0 ]]; then
    log_error "Verification FAILED."
    exit 1
fi

log_info "Verification PASSED. No-downtime criteria met."