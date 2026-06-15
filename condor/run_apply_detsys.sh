#!/bin/bash
set -euo pipefail

# Phase-2 detector variation systematics runner.
# Loads pre-built splines from a phase-1 output and applies detector variation
# weights to a single per-job selection output. No CAF files required.
#
# Environment variables (set via jobsub -e):
#   MEDULLA_BRANCH      - medulla git branch (default: develop)
#   MEDULLA_OUTPUT_DIR  - remote destination directory (PNFS path)
#   MEDULLA_DETSYS_TOML - apply-detsys TOML filename relative to dropbox dir
#   INPUT_FILE          - PNFS or xrootd path to this job's selection ROOT file
#   SPLINES_FILE        - PNFS or xrootd path to the phase-1 splines ROOT file

BRANCH="${MEDULLA_BRANCH:-develop}"
OUTPUT_DIR="${MEDULLA_OUTPUT_DIR:-}"
DETSYS_TOML="${MEDULLA_DETSYS_TOML:-NuMI_nue_apply_detsys.toml}"

jobNum="${JOBSUBJOBSECTION:-${PROCESS:-0}}"
if [[ ! "$jobNum" =~ ^[0-9]+$ ]]; then
  jobNum=0
fi

log_spool_dir="${CONDOR_DIR_INPUT:-$PWD}"
mkdir -p "$log_spool_dir"
errFile="${log_spool_dir}/detsys_${jobNum}.err"
outFile="${log_spool_dir}/detsys_${jobNum}.out"

exec > >(tee -a "$outFile") 2> >(tee -a "$errFile" >&2)

if [[ -n "$OUTPUT_DIR" ]]; then
  subdir=$(printf "%02d" "$((jobNum / 100))")
  log_dir="${OUTPUT_DIR}/logs/${subdir}"
else
  log_dir=""
fi

export CAFANA_DISABLE_SNAPSHOTS=1

cleanup_and_exit() {
  local exit_code=$?
  echo "[INFO] Cleanup: transferring logs before exit with code $exit_code"
  if [[ -n "$log_dir" ]]; then
    if command -v ifdh >/dev/null 2>&1; then
      if ! ifdh ls "$log_dir" >/dev/null 2>&1; then
        ifdh mkdir "$log_dir" 2>/dev/null || true
      fi
      [[ -f "$errFile" ]] && ifdh cp "$errFile" "$log_dir/detsys_${jobNum}.err" 2>/dev/null || true
      [[ -f "$outFile" ]] && ifdh cp "$outFile" "$log_dir/detsys_${jobNum}.out" 2>/dev/null || true
    fi
  fi
  return "$exit_code"
}
trap cleanup_and_exit EXIT

TOML_DIR="${INPUT_TAR_DIR_LOCAL:-.}"

# Resolve INPUT_FILE from inputs.txt when the bulk-submit sentinel is present.
if [[ "${INPUT_FILE:-}" == "__FROM_INPUTS_TXT__" ]]; then
  IDX="${PROCESS:-${JOBSUBJOBSECTION:-0}}"
  LINE_NO=$((IDX + 1))
  INPUTS_FILE="$TOML_DIR/inputs.txt"
  if [[ ! -f "$INPUTS_FILE" ]]; then
    echo "[ERROR] inputs.txt not found in $TOML_DIR"
    exit 2
  fi
  INPUT_FILE="$(sed -n "${LINE_NO}p" "$INPUTS_FILE")"
  if [[ -z "$INPUT_FILE" ]]; then
    echo "[ERROR] No entry for index $IDX in inputs.txt"
    exit 2
  fi
  echo "[INFO] Resolved INPUT_FILE[$IDX]: $INPUT_FILE"
fi

export IFDH_CP_MAXRETRIES=0
export IFDH_WEB_TIMEOUT=100

set +ue
source /cvmfs/icarus.opensciencegrid.org/products/icarus/setup_icarus.sh
setup sbnana v10_01_02_01 -q e26:prof
setup cmake v3_27_4
set -ue

echo "[INFO] Branch:       $BRANCH"
echo "[INFO] Job index:    $jobNum"
echo "[INFO] TOML:         $DETSYS_TOML"
echo "[INFO] Input file:   ${INPUT_FILE:-<none>}"
echo "[INFO] Splines file: ${SPLINES_FILE:-<none>}"
echo "[INFO] Output dir:   ${OUTPUT_DIR:-(none)}"

rm -rf medulla
git clone https://github.com/justinjmueller/medulla.git
cd medulla
git checkout "$BRANCH"
mkdir -p build
cd build
export CC=$(which gcc)
export CXX=$(which g++)
cmake .. -DCMAKE_CXX_STANDARD=17 -DCMAKE_CXX_COMPILER=$CXX -DCMAKE_C_COMPILER=$CC
make -j4

# Stage the apply-detsys TOML from the dropbox-mounted directory
TOML_PATH="$TOML_DIR/$DETSYS_TOML"
if [[ ! -f "$TOML_PATH" ]]; then
  echo "[ERROR] TOML not found: $TOML_PATH"
  ls -la "$TOML_DIR" 2>/dev/null | head -20 || true
  exit 2
fi
cp "$TOML_PATH" systematics.toml

# Stage this job's selection output locally
if [[ -n "${INPUT_FILE:-}" ]]; then
  if [[ "${INPUT_FILE}" == *root://* ]]; then
    local_input="$INPUT_FILE"
    echo "[INFO] Using xrootd input: $INPUT_FILE"
  else
    local_input="${log_spool_dir}/$(basename "$INPUT_FILE")"
    echo "[INFO] Staging input: $INPUT_FILE -> $local_input"
    ifdh cp "$INPUT_FILE" "$local_input"
  fi
else
  echo "[ERROR] INPUT_FILE is not set"
  exit 2
fi

# Stage the phase-1 splines file locally
if [[ -n "${SPLINES_FILE:-}" ]]; then
  if [[ "${SPLINES_FILE}" == *root://* ]]; then
    local_splines="$SPLINES_FILE"
    echo "[INFO] Using xrootd splines: $SPLINES_FILE"
  else
    local_splines="${log_spool_dir}/$(basename "$SPLINES_FILE")"
    echo "[INFO] Staging splines: $SPLINES_FILE -> $local_splines"
    ifdh cp "$SPLINES_FILE" "$local_splines"
  fi
else
  echo "[ERROR] SPLINES_FILE is not set"
  exit 2
fi

# Rewrite [input] path, [output] path, and [variations] splines_file in the
# TOML using awk so section boundaries are respected.
OUT_NAME="output_detsys_${jobNum}.root"
awk -v in_path="$local_input" \
    -v out_path="$OUT_NAME" \
    -v splines_path="$local_splines" '
  /^\[input\]/        { in_input=1; in_output=0; in_variations=0 }
  /^\[output\]/       { in_input=0; in_output=1; in_variations=0 }
  /^\[variations\]/   { in_input=0; in_output=0; in_variations=1 }
  /^\[[^]]+\]/ {
    if (!/^\[input\]/ && !/^\[output\]/ && !/^\[variations\]/)
      { in_input=0; in_output=0; in_variations=0 }
  }
  in_input && /^[[:space:]]*path[[:space:]]*=/ && !input_done {
    print "path = \047" in_path "\047"; input_done=1; next
  }
  in_output && /^[[:space:]]*path[[:space:]]*=/ && !output_done {
    print "path = \047" out_path "\047"; output_done=1; next
  }
  in_variations && /^[[:space:]]*splines_file[[:space:]]*=/ && !splines_done {
    print "splines_file = \047" splines_path "\047"; splines_done=1; next
  }
  { print }
' systematics.toml > systematics_rewritten.toml && mv systematics_rewritten.toml systematics.toml

echo "[INFO] TOML paths rewritten:"
echo "[INFO]   [input]      path         -> $local_input"
echo "[INFO]   [output]     path         -> $OUT_NAME"
echo "[INFO]   [variations] splines_file -> $local_splines"

echo "[INFO] Running run_systematics (add_detsys_weights mode)..."
if ! ./systematics/run_systematics systematics.toml; then
  sys_exit=$?
  echo "[ERROR] run_systematics failed with exit code $sys_exit"
  ls -la | head -30
  exit "$sys_exit"
fi
echo "[INFO] run_systematics completed"

if [[ ! -f "$OUT_NAME" ]]; then
  echo "[ERROR] Expected output not found: $OUT_NAME"
  find . -maxdepth 1 -name "*.root" | head -10
  exit 2
fi
echo "[INFO] Output: $OUT_NAME ($(stat -c%s "$OUT_NAME" 2>/dev/null || echo "?") bytes)"

if [[ -n "$OUTPUT_DIR" ]]; then
  subdir=$(printf "%02d" "$((jobNum / 100))")
  DEST_DIR="${OUTPUT_DIR}/outputs/${subdir}"
  echo "[INFO] Transferring to $DEST_DIR/"
  if ifdh cp "$OUT_NAME" "$DEST_DIR/"; then
    echo "[INFO] Staged: $DEST_DIR/$OUT_NAME"
  else
    echo "[ERROR] ifdh cp failed"
    exit 41
  fi
else
  echo "[INFO] OUTPUT_DIR not set; output remains in sandbox"
fi

echo "[INFO] Done."
