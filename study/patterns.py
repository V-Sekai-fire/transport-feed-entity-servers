"""The two log-line patterns spread.py reads. Each value may carry a trailing `ns` (new
format, p50=15589ns) or none (old format, p50=15589), so both the logs already in the
Actions history and new logs parse. Only digits are captured."""
import re
N = r"(\d+)(?:ns)?"
CHECK = re.compile(rf"ticks=(\d+) .*overruns=(\d+) p50={N} p95={N} p99={N} max={N}")
LAYOUT = re.compile(rf"[AB] cpus=\S+ p50={N} p95={N} p99={N} max={N}")
