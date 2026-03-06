#!/usr/bin/env bash

# Usage: ./scripts/run_super_mario.sh <N>
# Optional env overrides:
#   NVIDIA_API_KEY, NVIDIA_API_BASE_URL (default: https://integrate.api.nvidia.com/v1)
#   LLM_NAME (default: nvidia/nvidia-nemotron-nano-9b-v2)
#   AGENT_TYPE (default: reflection_planning_agent)
#   INPUT_MODALITY (default: text)

set -u

if [ $# -lt 1 ]; then
  echo "Usage: $0 <N_runs>" >&2
  exit 1
fi

N_RUNS=$1

# Resolve repo root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
export REPO_ROOT

# Defaults
LLM_NAME="${LLM_NAME:-nvidia/nvidia-nemotron-nano-9b-v2}"
AGENT_TYPE="${AGENT_TYPE:-reflection_planning_agent}"
INPUT_MODALITY="${INPUT_MODALITY:-text}"
NVIDIA_API_BASE_URL="${NVIDIA_API_BASE_URL:-https://integrate.api.nvidia.com/v1}"

# Ensure PYTHONPATH includes src
export PYTHONPATH="$REPO_ROOT/src${PYTHONPATH:+:$PYTHONPATH}"

CONFIG_PATH="$REPO_ROOT/src/mcp_agent_client/configs/super_mario/config.yaml"
PLAY_PY="$REPO_ROOT/scripts/mcp_play_game.py"

echo "Running Super Mario $N_RUNS time(s)..." >&2

# Run N times; tolerate non-zero exit to keep going
for ((i=1; i<=N_RUNS; i++)); do
  echo "Run $i/$N_RUNS ..." >&2
  python3 "$PLAY_PY" \
    --config "$CONFIG_PATH" \
    "env.input_modality=$INPUT_MODALITY" \
    "agent.llm_name=$LLM_NAME" \
    "agent.agent_type=$AGENT_TYPE" \
    ${NVIDIA_API_KEY:+"agent.api_key=$NVIDIA_API_KEY"} \
    ${NVIDIA_API_BASE_URL:+"agent.api_base_url=$NVIDIA_API_BASE_URL"} \
    "agent.prompt_path=mcp_agent_servers.super_mario.prompts.$INPUT_MODALITY.$AGENT_TYPE"
  status=$?
  if [ $status -ne 0 ]; then
    echo "  Warning: process exited with code $status; continuing" >&2
  fi
done

# Collect latest N results and summarize (fallback to client.log if final_score.json missing)
python3 - "$N_RUNS" << 'PY'
import sys, os, glob, json, statistics, re

repo_root = os.environ.get('REPO_ROOT', os.getcwd())
logs_root = os.path.join(repo_root, 'logs', 'SuperMario')
MAX_DISTANCE = 3161  # distance to flag for normalization

def latest_n(paths, n):
    paths = [p for p in paths if os.path.exists(p)]
    paths.sort(key=os.path.getmtime, reverse=True)
    return paths[:n]

def read_score_json(fp):
    try:
        with open(fp, 'r', encoding='utf-8') as f:
            data = json.load(f)
        return int(data.get('score', 0))
    except Exception:
        return None

def read_score_from_log(fp):
    try:
        with open(fp, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read()
        matches = re.findall(r"^.*?Score:\s*(\d+)\s*$", content, flags=re.MULTILINE)
        if matches:
            return int(matches[-1])
    except Exception:
        pass
    return None

try:
    n = int(sys.argv[1])
except Exception:
    n = 5

# 1) Prefer latest N final_score.json
json_files = glob.glob(os.path.join(logs_root, '**', 'final_score.json'), recursive=True)
json_files = latest_n(json_files, n)
scores = []
used_dirs = set()
for fp in json_files:
    sc = read_score_json(fp)
    if sc is not None:
        scores.append(sc)
        used_dirs.add(os.path.dirname(fp))

# 2) Fallback: parse client.log and game_server.log for remaining slots
if len(scores) < n:
    log_files = latest_n(glob.glob(os.path.join(logs_root, '**', 'client.log'), recursive=True), n*3)
    gs_log_files = latest_n(glob.glob(os.path.join(logs_root, '**', 'game_server.log'), recursive=True), n*3)
    for fp in log_files + gs_log_files:
        if len(scores) >= n:
            break
        if os.path.dirname(fp) in used_dirs:
            continue
        sc = read_score_from_log(fp)
        if sc is not None:
            scores.append(sc)
            used_dirs.add(os.path.dirname(fp))

if not scores:
    print('Scores: []')
    print('Mean: 0.00')
    print('Std: 0.00')
    print('NormScores: []')
    print('NormMean: 0.00')
    print('NormStd: 0.00')
    sys.exit(0)

mean_val = statistics.mean(scores)
std_val = statistics.stdev(scores) if len(scores) > 1 else 0.0

# Normalized scores in [0,1]
norm_scores = [max(0.0, min(1.0, sc / MAX_DISTANCE)) for sc in scores]
norm_mean = statistics.mean(norm_scores)
norm_std = statistics.stdev(norm_scores) if len(norm_scores) > 1 else 0.0

print(f'Scores: {scores}')
print(f'Mean: {mean_val:.2f}')
print(f'Std: {std_val:.2f}')
print(f'NormScores: {[round(x, 4) for x in norm_scores]}')
print(f'NormMean: {norm_mean:.4f}')
print(f'NormStd: {norm_std:.4f}')
PY


