#!/bin/bash
set -euo pipefail

# Prefer environment variables passed via jobsub -e; keep positional fallbacks.
CFG_IN="${MEDULLA_CFG_MODE:-${1:-__FROM_JOBS_TXT__}}"
BRANCH="${MEDULLA_BRANCH:-${2:-develop}}"
JOBID="${3:-0}"
OUTPUT_DIR="${MEDULLA_OUTPUT_DIR:-${4:-}}"

# Use section index from jobsub when available.
jobNum="${JOBSUBJOBSECTION:-${PROCESS:-$JOBID}}"
if [[ ! "$jobNum" =~ ^[0-9]+$ ]]; then
  jobNum=0
fi

# Local spool location for logs inside the job sandbox.
log_spool_dir="${CONDOR_DIR_INPUT:-$PWD}"
mkdir -p "$log_spool_dir"
errFile="${log_spool_dir}/job_${jobNum}.err"
outFile="${log_spool_dir}/job_${jobNum}.out"

# Redirect stdout/stderr so job messages are always captured in files.
exec > >(tee -a "$outFile") 2> >(tee -a "$errFile" >&2)

# Optional remote log destination (grouped by 100 jobs): <outputDir>/logs/XX
if [[ -n "$OUTPUT_DIR" ]]; then
  subdir=$(printf "%02d" "$((jobNum / 100))")
  log_dir="${OUTPUT_DIR}/logs/${subdir}"
else
  log_dir=""
fi

# Disable CAFAna snapshots
export CAFANA_DISABLE_SNAPSHOTS=1

# Cleanup function to transfer logs before exit (never masks original exit code).
cleanup_and_exit() {
  local exit_code=$?
  echo "[INFO] Cleanup: transferring log files before exit with code $exit_code"

  if [[ -n "$log_dir" ]]; then
    if command -v ifdh >/dev/null 2>&1; then
      if ! ifdh ls "$log_dir" >/dev/null 2>&1; then
        echo "[INFO] Creating log directory: $log_dir"
        ifdh mkdir "$log_dir" 2>/dev/null || true
      fi

      local errFileName="job_${jobNum}.err"
      local outFileName="job_${jobNum}.out"

      if [[ -f "$errFile" ]]; then
        echo "[INFO] Transferring err file to $log_dir/$errFileName"
        ifdh cp "$errFile" "$log_dir/$errFileName" 2>/dev/null || echo "[WARN] Failed to transfer $errFile"
      fi

      if [[ -f "$outFile" ]]; then
        echo "[INFO] Transferring out file to $log_dir/$outFileName"
        ifdh cp "$outFile" "$log_dir/$outFileName" 2>/dev/null || echo "[WARN] Failed to transfer $outFile"
      fi
    else
      echo "[WARN] ifdh is not available; skipping remote log transfer"
    fi
  fi

  return "$exit_code"
}
trap cleanup_and_exit EXIT

# Dropbox-mounted directory containing all TOMLs and jobs.txt
# Provided by jobsub --tar_file_name and --use-cvmfs-dropbox
TOML_DIR="${INPUT_TAR_DIR_LOCAL:-.}"

# Bulk-submit mode: resolve per-job config from jobs.txt using PROCESS index.
if [[ "$CFG_IN" == "__FROM_JOBS_TXT__" ]]; then
  IDX="${PROCESS:-${JOBSUBJOBSECTION:-0}}"
  if ! [[ "$IDX" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] Invalid PROCESS/JOBSUBJOBSECTION index: '$IDX'"
    exit 2
  fi
  LINE_NO=$((IDX + 1))
  JOBS_FILE="$TOML_DIR/jobs.txt"
  if [[ ! -f "$JOBS_FILE" ]]; then
    echo "[ERROR] jobs.txt not found in $TOML_DIR"
    exit 2
  fi
  CFG_IN="$(sed -n "${LINE_NO}p" "$JOBS_FILE")"
  if [[ -z "$CFG_IN" ]]; then
    echo "[ERROR] No config entry for index ${IDX} (line ${LINE_NO})"
    exit 2
  fi
  JOBID="$IDX"
fi

echo "[INFO] Resolved config: $CFG_IN (job index: $JOBID)"

# IFDH options (for PNFS copies)
export IFDH_CP_MAXRETRIES=0
export IFDH_WEB_TIMEOUT=100

# Setup CVMFS area
set +ue
source /cvmfs/icarus.opensciencegrid.org/products/icarus/setup_icarus.sh
# Dependencies (match medulla/batch/submit.sh defaults)
setup sbnana v10_01_02_01 -q e26:prof
setup cmake v3_27_4
set -ue

echo "[INFO] Using config: $CFG_IN"
echo "[INFO] Building Medulla branch: $BRANCH"
echo "[INFO] Job id: $JOBID"
echo "[INFO] TOML directory: $TOML_DIR"
echo "[INFO] Output directory: ${OUTPUT_DIR:-(none)}"

# Build Medulla
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

# Stage job config from the mounted dropbox directory
TOML_PATH="$TOML_DIR/$CFG_IN"
if [[ ! -f "$TOML_PATH" ]]; then
  echo "[ERROR] Could not locate TOML: $TOML_PATH"
  echo "[DEBUG] Contents of $TOML_DIR:"
  ls -la "$TOML_DIR" 2>/dev/null | head -20 || echo "  (directory not accessible)"
  exit 2
fi

cp "$TOML_PATH" job_config.toml
echo "[INFO] Copied TOML: $TOML_PATH -> job_config.toml"

# If an input file was provided, stage it locally and rewrite any matching
# TOML path entries so the job reads the local copy instead of PNFS.
if [[ -n "${INPUT_FILE:-}" ]]; then
  local_input_file="$INPUT_FILE"
  if [[ "${INPUT_FILE}" == *root://* ]]; then
    echo "Using xrootd file ${INPUT_FILE}";
  else
    local_input_file="${log_spool_dir}/$(basename "$INPUT_FILE")"
    echo "[INFO] Staging INPUT_FILE locally: $INPUT_FILE -> $local_input_file"
    if command -v ifdh >/dev/null 2>&1; then
      ifdh cp "$INPUT_FILE" "$local_input_file"
    else
      echo "[ERROR] ifdh is not available; cannot stage INPUT_FILE"
      exit 2
    fi
  fi

  if [[ -f "job_config.toml" ]]; then
    # Escape replacement-sensitive characters for sed.
    local_input_escaped="$local_input_file"
    local_input_escaped=${local_input_escaped//&/\&}
    local_input_escaped=${local_input_escaped//|/\|}
    if grep -qE "^[[:space:]]*path[[:space:]]*=" job_config.toml; then
      sed -i"" -E "0,/^[[:space:]]*path[[:space:]]*=[[:space:]]*.*/s|^[[:space:]]*path[[:space:]]*=[[:space:]]*.*|path = '${local_input_escaped}'|" job_config.toml
      echo "[INFO] Rewrote TOML path to local input: $local_input_file"
    else
      echo "[INFO] No path = ... entry found in job_config.toml"
    fi
  fi
fi

# Run selection
echo "[INFO] Starting medulla selection..."
echo "[DEBUG] Current working directory: $PWD"
echo "[DEBUG] Files before running medulla:"
ls -la | head -20
if ! ./selection/medulla job_config.toml; then
  medulla_exit=$?
  echo "[ERROR] Medulla selection failed with exit code $medulla_exit"
  echo "[DEBUG] Files after failed medulla run:"
  ls -la | head -30
  echo "[DEBUG] Checking for any .root files:"
  find . -maxdepth 1 -name "*.root" -type f -exec ls -lh {} \;
  exit "$medulla_exit"
fi
echo "[INFO] Medulla selection completed successfully"
echo "[DEBUG] Files after medulla run:"
ls -la | head -30

# Normalize output name to output_<JOBID>.root (Medulla uses [general].output + '.root')
OUT="output_${JOBID}.root"
echo "[DEBUG] Looking for output file, target name: $OUT"

if [[ -f output_nueCCInclusive.root ]]; then
  echo "[INFO] Found output_nueCCInclusive.root, renaming to $OUT"
  mv output_nueCCInclusive.root "$OUT"
elif compgen -G "output_*.root" > /dev/null; then
  # If exactly one output_*.root file exists, use it
  mapfile -t roots < <(ls -1 output_*.root 2>/dev/null | head -n 10)
  echo "[DEBUG] Found ${#roots[@]} output_*.root files: ${roots[@]}"
  if [[ ${#roots[@]} -eq 1 ]]; then
    echo "[INFO] Renaming ${roots[0]} to $OUT"
    [[ "$OUT" != "${roots[0]}" ]] && mv "${roots[0]}" "$OUT"
  elif [[ ${#roots[@]} -gt 1 ]]; then
    echo "[ERROR] Multiple output_*.root files present:"
    ls -1 output_*.root
    exit 2
  fi
elif compgen -G "*.root" > /dev/null; then
  # Fallback: any .root file
  mapfile -t roots < <(ls -1 *.root | head -n 10)
  echo "[DEBUG] Found ${#roots[@]} .root files in fallback: ${roots[@]}"
  if [[ ${#roots[@]} -eq 1 ]]; then
    echo "[INFO] Using fallback, renaming ${roots[0]} to $OUT"
    mv "${roots[0]}" "$OUT"
  else
    echo "[ERROR] Multiple .root outputs present; cannot choose one automatically:"
    ls -1 *.root
    exit 2
  fi
else
  echo "[ERROR] No .root output produced."
  echo "[DEBUG] Directory listing:"
  ls -la
  echo "[DEBUG] Checking stderr/stdout files:"
  [[ -f job_${jobNum}.err ]] && echo "=== stderr ===" && tail -50 job_${jobNum}.err
  [[ -f job_${jobNum}.out ]] && echo "=== stdout ===" && tail -50 job_${jobNum}.out
  exit 2
fi

# Verify output file exists and is not empty
if [[ ! -f "$OUT" ]]; then
  echo "[ERROR] Output file $OUT does not exist after rename/move"
  exit 2
fi
OUT_SIZE=$(stat -f%z "$OUT" 2>/dev/null || stat -c%s "$OUT" 2>/dev/null || echo "unknown")
echo "[INFO] Output file confirmed: $OUT (size: $OUT_SIZE bytes)"

# Stage outputs under OUTPUT_DIR/outputs/<XX>, where XX groups jobs by 100.
if [[ -n "$OUTPUT_DIR" ]]; then
  out_subdir=$(printf "%02d" "$((jobNum / 100))")
  DEST_DIR="${OUTPUT_DIR}/outputs/${out_subdir}"
  echo "[INFO] Output directory resolved to: $DEST_DIR"
  echo "[INFO] Attempting to transfer $OUT to $DEST_DIR/"
  if ifdh cp "$OUT" "$DEST_DIR/"; then
    echo "[INFO] Staged output to: $DEST_DIR/$OUT"
  else
    ifdh_exit=$?
    echo "[ERROR] ifdh cp failed with exit code $ifdh_exit"
    echo "[ERROR] Could not stage output to $DEST_DIR/$OUT"
    echo "[DEBUG] ifdh command: ifdh cp $OUT $DEST_DIR/"
    exit 41
  fi
else
  echo "[INFO] OUTPUT_DIR is not set; output remains in job sandbox"
fi

echo "[INFO] Done. Produced: $OUT"
