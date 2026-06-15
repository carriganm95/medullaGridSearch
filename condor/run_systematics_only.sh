#!/bin/bash
set -euo pipefail

# Systematics-only job runner.
# Builds medulla, stages a merged selection output and a systematics TOML,
# then runs run_systematics without a prior selection step.
#
# Intended for use after merging selection outputs from all grid jobs.
#
# Environment variables (set via jobsub -e):
#   MEDULLA_BRANCH      - medulla git branch to checkout (default: develop)
#   MEDULLA_OUTPUT_DIR  - remote destination directory for output (PNFS path)
#   MEDULLA_SYS_TOML    - systematics TOML filename relative to the dropbox dir
#   INPUT_FILE          - merged selection ROOT file (PNFS path or xrootd URI)
#   MEDULLA_SYS_OUTPUT  - output filename written locally (default: output_sys.root)

BRANCH="${MEDULLA_BRANCH:-develop}"
OUTPUT_DIR="${MEDULLA_OUTPUT_DIR:-}"
SYS_TOML="${MEDULLA_SYS_TOML:-systematics.toml}"
SYS_OUTPUT="${MEDULLA_SYS_OUTPUT:-output_sys.root}"

jobNum="${JOBSUBJOBSECTION:-${PROCESS:-0}}"
if [[ ! "$jobNum" =~ ^[0-9]+$ ]]; then
  jobNum=0
fi

log_spool_dir="${CONDOR_DIR_INPUT:-$PWD}"
mkdir -p "$log_spool_dir"
errFile="${log_spool_dir}/sysonly_${jobNum}.err"
outFile="${log_spool_dir}/sysonly_${jobNum}.out"

exec > >(tee -a "$outFile") 2> >(tee -a "$errFile" >&2)

if [[ -n "$OUTPUT_DIR" ]]; then
  log_dir="${OUTPUT_DIR}/logs"
else
  log_dir=""
fi

export CAFANA_DISABLE_SNAPSHOTS=1

cleanup_and_exit() {
  local exit_code=$?
  echo "[INFO] Cleanup: transferring log files before exit with code $exit_code"
  if [[ -n "$log_dir" ]]; then
    if command -v ifdh >/dev/null 2>&1; then
      if ! ifdh ls "$log_dir" >/dev/null 2>&1; then
        ifdh mkdir "$log_dir" 2>/dev/null || true
      fi
      [[ -f "$errFile" ]] && ifdh cp "$errFile" "$log_dir/sysonly_${jobNum}.err" 2>/dev/null || true
      [[ -f "$outFile" ]] && ifdh cp "$outFile" "$log_dir/sysonly_${jobNum}.out" 2>/dev/null || true
    fi
  fi
  return "$exit_code"
}
trap cleanup_and_exit EXIT

TOML_DIR="${INPUT_TAR_DIR_LOCAL:-.}"

export IFDH_CP_MAXRETRIES=0
export IFDH_WEB_TIMEOUT=100

set +ue
source /cvmfs/icarus.opensciencegrid.org/products/icarus/setup_icarus.sh
setup sbnana v10_01_02_01 -q e26:prof
setup cmake v3_27_4
set -ue

echo "[INFO] Building Medulla branch: $BRANCH"
echo "[INFO] Systematics TOML: $SYS_TOML"
echo "[INFO] Input file: ${INPUT_FILE:-<none>}"
echo "[INFO] Output: $SYS_OUTPUT"
echo "[INFO] Output directory: ${OUTPUT_DIR:-(none)}"

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

# Stage the systematics TOML from the dropbox-mounted directory
SYS_TOML_PATH="$TOML_DIR/$SYS_TOML"
if [[ ! -f "$SYS_TOML_PATH" ]]; then
  echo "[ERROR] Systematics TOML not found: $SYS_TOML_PATH"
  echo "[DEBUG] Contents of $TOML_DIR:"
  ls -la "$TOML_DIR" 2>/dev/null | head -20 || echo "  (directory not accessible)"
  exit 2
fi
cp "$SYS_TOML_PATH" systematics.toml
echo "[INFO] Copied systematics TOML: $SYS_TOML_PATH -> systematics.toml"

# Stage the merged input file locally and rewrite paths in the TOML.
if [[ -n "${INPUT_FILE:-}" ]]; then
  if [[ "${INPUT_FILE}" == *root://* ]]; then
    local_input_file="$INPUT_FILE"
    echo "[INFO] Using xrootd input: $INPUT_FILE"
  else
    local_input_file="${log_spool_dir}/$(basename "$INPUT_FILE")"
    echo "[INFO] Staging merged input file: $INPUT_FILE -> $local_input_file"
    if command -v ifdh >/dev/null 2>&1; then
      ifdh cp "$INPUT_FILE" "$local_input_file"
    else
      echo "[ERROR] ifdh not available; cannot stage INPUT_FILE"
      exit 2
    fi
  fi

  # Rewrite [input] path and [output] path in the TOML using awk so that
  # section boundaries are respected (avoids sed clobbering the wrong path).
  awk -v in_path="$local_input_file" -v out_path="$SYS_OUTPUT" '
    /^\[input\]/  { in_input=1; in_output=0 }
    /^\[output\]/ { in_input=0; in_output=1 }
    /^\[[^]]+\]/  { if (!/^\[input\]/ && !/^\[output\]/) { in_input=0; in_output=0 } }
    in_input && /^[[:space:]]*path[[:space:]]*=/ && !input_done {
      print "path = \047" in_path "\047"
      input_done=1; next
    }
    in_output && /^[[:space:]]*path[[:space:]]*=/ && !output_done {
      print "path = \047" out_path "\047"
      output_done=1; next
    }
    { print }
  ' systematics.toml > systematics_rewritten.toml && mv systematics_rewritten.toml systematics.toml
  echo "[INFO] Rewrote TOML: [input] path -> $local_input_file"
  echo "[INFO] Rewrote TOML: [output] path -> $SYS_OUTPUT"
fi

# Run systematics
echo "[INFO] Starting run_systematics..."
echo "[DEBUG] Current working directory: $PWD"
echo "[DEBUG] Files before running run_systematics:"
ls -la | head -20
if ! ./systematics/run_systematics systematics.toml; then
  sys_exit=$?
  echo "[ERROR] run_systematics failed with exit code $sys_exit"
  echo "[DEBUG] Files after failed run:"
  ls -la | head -30
  exit "$sys_exit"
fi
echo "[INFO] run_systematics completed successfully"
echo "[DEBUG] Files after run_systematics:"
ls -la | head -20

# Verify output exists
if [[ ! -f "$SYS_OUTPUT" ]]; then
  echo "[ERROR] Expected output file not found: $SYS_OUTPUT"
  echo "[DEBUG] .root files present:"
  find . -maxdepth 1 -name "*.root" -type f -exec ls -lh {} \;
  exit 2
fi
SYS_SIZE=$(stat -c%s "$SYS_OUTPUT" 2>/dev/null || echo "unknown")
echo "[INFO] Output confirmed: $SYS_OUTPUT (size: $SYS_SIZE bytes)"

# Transfer output to the remote destination
if [[ -n "$OUTPUT_DIR" ]]; then
  echo "[INFO] Transferring $SYS_OUTPUT to $OUTPUT_DIR/"
  if ifdh cp "$SYS_OUTPUT" "$OUTPUT_DIR/"; then
    echo "[INFO] Staged output to: $OUTPUT_DIR/$SYS_OUTPUT"
  else
    ifdh_exit=$?
    echo "[ERROR] ifdh cp failed with exit code $ifdh_exit"
    echo "[ERROR] Could not stage output to $OUTPUT_DIR/$SYS_OUTPUT"
    exit 41
  fi
else
  echo "[INFO] OUTPUT_DIR not set; output remains in job sandbox"
fi

echo "[INFO] Done. Produced: $SYS_OUTPUT"
