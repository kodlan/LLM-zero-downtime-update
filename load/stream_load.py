#!/usr/bin/env python3
"""
stream_load.py - Streaming load generator for vLLM OpenAI-compatible API.

Sends concurrent streaming completion requests, collects per-request metrics
(TTFT, tokens/sec, errors), and produces a summary report.

Usage:
    python3 load/stream_load.py --url http://localhost:8000 --concurrency 4 --duration 30
"""

import argparse
import dataclasses
import json
import os
import random
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

try:
    import requests
except ImportError:
    print("Missing dependency: requests. Install with: pip install requests")
    sys.exit(1)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_PROMPTS = [
    "Explain the concept of zero-downtime deployment in three sentences.",
    "Write a short Python function that reverses a string.",
    "What is the difference between blue-green and canary deployments?",
    "Summarize the benefits of container orchestration.",
    "Describe how a load balancer distributes traffic.",
]

GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[1;33m"
CYAN = "\033[0;36m"
NC = "\033[0m"

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------


@dataclasses.dataclass
class RequestResult:
    request_id: int
    start_time: float
    ttft: float  # time to first token (seconds), 0 if no token received
    total_time: float
    tokens_received: int
    status_code: int
    error: str  # empty string = success
    stream_completed: bool
    finish_reason: str  # "stop", "length", etc., or empty


# ---------------------------------------------------------------------------
# Core functions
# ---------------------------------------------------------------------------


def send_streaming_request(
    session: requests.Session,
    url: str,
    model: str,
    prompt: str,
    max_tokens: int,
    request_id: int,
) -> RequestResult:
    """Send a single streaming POST to /v1/completions and parse SSE."""
    endpoint = f"{url}/v1/completions"
    payload = {
        "model": model,
        "prompt": prompt,
        "max_tokens": max_tokens,
        "stream": True,
    }
    result = RequestResult(
        request_id=request_id,
        start_time=time.time(),
        ttft=0.0,
        total_time=0.0,
        tokens_received=0,
        status_code=0,
        error="",
        stream_completed=False,
        finish_reason="",
    )

    try:
        resp = session.post(endpoint, json=payload, stream=True, timeout=120)
        result.status_code = resp.status_code

        if resp.status_code != 200:
            result.error = f"HTTP {resp.status_code}"
            result.total_time = time.time() - result.start_time
            return result

        first_token_time = None
        for line in resp.iter_lines(decode_unicode=True):
            if not line or not line.startswith("data: "):
                continue
            data_str = line[len("data: "):]
            if data_str.strip() == "[DONE]":
                result.stream_completed = True
                break
            try:
                data = json.loads(data_str)
                choices = data.get("choices", [{}])
                text = choices[0].get("text", "") if choices else ""
                finish = choices[0].get("finish_reason") if choices else None
                if text:
                    result.tokens_received += 1
                    if first_token_time is None:
                        first_token_time = time.time()
                        result.ttft = first_token_time - result.start_time
                if finish is not None:
                    result.finish_reason = finish
                    result.stream_completed = True
            except (json.JSONDecodeError, IndexError, KeyError):
                pass

    except requests.exceptions.ConnectionError:
        result.error = "connection_reset"
    except requests.exceptions.ChunkedEncodingError:
        result.error = "stream_interrupted"
    except requests.exceptions.Timeout:
        result.error = "timeout"
    except Exception as e:
        result.error = str(e)

    result.total_time = time.time() - result.start_time
    return result


def worker(
    url: str,
    model: str,
    prompts: list,
    max_tokens: int,
    stop_event: threading.Event,
    results: list,
    results_lock: threading.Lock,
    worker_id: int,
    request_counter: list,
    counter_lock: threading.Lock,
):
    """Worker loop: send streaming requests until stop_event is set."""
    session = requests.Session()
    while not stop_event.is_set():
        prompt = random.choice(prompts)
        with counter_lock:
            req_id = request_counter[0]
            request_counter[0] += 1
        result = send_streaming_request(session, url, model, prompt, max_tokens, req_id)
        with results_lock:
            results.append(result)
    session.close()


def percentile(sorted_values: list, p: float) -> float:
    """Compute p-th percentile from a sorted list. p in [0, 100]."""
    if not sorted_values:
        return 0.0
    k = (len(sorted_values) - 1) * (p / 100.0)
    f = int(k)
    c = min(f + 1, len(sorted_values) - 1)
    d = k - f
    return sorted_values[f] + d * (sorted_values[c] - sorted_values[f])


def compute_metrics(results: list, start_time: float, end_time: float) -> dict:
    """Aggregate results into summary metrics."""
    total = len(results)
    if total == 0:
        return {
            "total_requests": 0,
            "successful": 0,
            "failed": 0,
            "error_rate": 0.0,
            "status_code_counts": {},
            "ttft_p50": 0.0,
            "ttft_p95": 0.0,
            "tokens_per_sec": 0.0,
            "stream_completion_rate": 0.0,
            "duration_actual": end_time - start_time,
        }

    successful = sum(1 for r in results if not r.error)
    failed = total - successful
    error_rate = failed / total if total > 0 else 0.0

    status_counts = {}
    for r in results:
        key = str(r.status_code)
        status_counts[key] = status_counts.get(key, 0) + 1

    ttft_values = sorted([r.ttft for r in results if r.ttft > 0])
    total_tokens = sum(r.tokens_received for r in results)
    duration = end_time - start_time
    tokens_per_sec = total_tokens / duration if duration > 0 else 0.0

    completed_streams = sum(1 for r in results if r.stream_completed)
    stream_completion_rate = completed_streams / total if total > 0 else 0.0

    return {
        "total_requests": total,
        "successful": successful,
        "failed": failed,
        "error_rate": round(error_rate, 4),
        "status_code_counts": status_counts,
        "ttft_p50": round(percentile(ttft_values, 50), 4),
        "ttft_p95": round(percentile(ttft_values, 95), 4),
        "tokens_per_sec": round(tokens_per_sec, 1),
        "stream_completion_rate": round(stream_completion_rate, 4),
        "duration_actual": round(duration, 1),
    }


def print_summary(metrics: dict):
    """Print a formatted text summary."""
    print()
    print("============================================")
    print("  Streaming Load Test Results")
    print("============================================")
    print()
    print(f"  Duration:              {metrics['duration_actual']}s")
    print(f"  Total requests:        {metrics['total_requests']}")
    print(f"  {GREEN}Successful{NC}:           {metrics['successful']}")
    print(f"  {RED}Failed{NC}:               {metrics['failed']}")
    print(f"  Error rate:            {metrics['error_rate'] * 100:.1f}%")
    print()
    print(f"  Stream completion:     {metrics['stream_completion_rate'] * 100:.1f}%")
    print(f"  Tokens/sec:            {metrics['tokens_per_sec']}")
    print(f"  TTFT p50:              {metrics['ttft_p50'] * 1000:.1f}ms")
    print(f"  TTFT p95:              {metrics['ttft_p95'] * 1000:.1f}ms")
    print()

    if metrics["status_code_counts"]:
        print("  Status codes:")
        for code, count in sorted(metrics["status_code_counts"].items()):
            print(f"    {code}: {count}")
        print()

    if metrics["error_rate"] > 0.05:
        print(f"  {RED}[WARN] Error rate exceeds 5% threshold{NC}")
    if metrics["stream_completion_rate"] < 0.90:
        print(f"  {RED}[WARN] Stream completion rate below 90%{NC}")

    print("============================================")
    print()


def write_json_output(metrics: dict, results: list, path: str):
    """Write metrics + per-request detail to JSON file."""
    output = {
        "metrics": metrics,
        "requests": [dataclasses.asdict(r) for r in results],
    }
    tmp_path = path + ".tmp"
    with open(tmp_path, "w") as f:
        json.dump(output, f, indent=2)
    os.replace(tmp_path, path)
    print(f"  Results written to: {path}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def load_prompts(prompts_file: str) -> list:
    """Load prompts from file or return defaults."""
    if prompts_file:
        with open(prompts_file) as f:
            prompts = [line.strip() for line in f if line.strip()]
        if prompts:
            return prompts
        print(f"{YELLOW}[WARN]{NC} Prompts file empty, using defaults.")
    return DEFAULT_PROMPTS


def main():
    parser = argparse.ArgumentParser(description="Streaming load generator for vLLM")
    parser.add_argument("--url", default="http://localhost:8000", help="vLLM base URL")
    parser.add_argument(
        "--model",
        default="Qwen/Qwen2.5-0.5B-Instruct",
        help="Model name for API requests",
    )
    parser.add_argument(
        "-c", "--concurrency", type=int, default=4, help="Number of concurrent workers"
    )
    parser.add_argument(
        "-d", "--duration", type=int, default=30, help="Test duration in seconds"
    )
    parser.add_argument(
        "--max-tokens", type=int, default=100, help="Max tokens per completion"
    )
    parser.add_argument(
        "-o", "--output", default="", help="Path for JSON results file"
    )
    parser.add_argument(
        "--prompts-file", default="", help="File with one prompt per line"
    )
    args = parser.parse_args()

    prompts = load_prompts(args.prompts_file)

    # Pre-flight health check
    print(f"{GREEN}[INFO]{NC} Checking endpoint: {args.url}/health")
    try:
        resp = requests.get(f"{args.url}/health", timeout=5)
        if resp.status_code != 200:
            print(
                f"{RED}[ERROR]{NC} Health check returned {resp.status_code}. "
                "Is vLLM running?"
            )
            sys.exit(1)
    except requests.exceptions.ConnectionError:
        print(
            f"{RED}[ERROR]{NC} Cannot reach {args.url}. "
            "Is port-forward running? Try: make port-forward"
        )
        sys.exit(1)

    print(f"{GREEN}[INFO]{NC} Endpoint healthy.")
    print(
        f"{GREEN}[INFO]{NC} Starting load test: "
        f"concurrency={args.concurrency}, duration={args.duration}s, "
        f"max_tokens={args.max_tokens}"
    )

    results = []
    results_lock = threading.Lock()
    request_counter = [0]
    counter_lock = threading.Lock()
    stop_event = threading.Event()

    start_time = time.time()

    with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
        futures = []
        for i in range(args.concurrency):
            fut = executor.submit(
                worker,
                args.url,
                args.model,
                prompts,
                args.max_tokens,
                stop_event,
                results,
                results_lock,
                i,
                request_counter,
                counter_lock,
            )
            futures.append(fut)

        # Wait for duration then signal workers to stop
        time.sleep(args.duration)
        stop_event.set()

        # Wait for workers to finish their in-flight requests
        for fut in futures:
            fut.result()

    end_time = time.time()

    metrics = compute_metrics(results, start_time, end_time)
    print_summary(metrics)

    if args.output:
        write_json_output(metrics, results, args.output)


if __name__ == "__main__":
    main()
