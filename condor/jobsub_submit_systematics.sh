#!/bin/bash
set -euo pipefail

# Submit a single systematics-only job that processes a merged selection output.
# Run this after merging selection outputs from all grid jobs with mergeFiles.sh.
#
# Usage:
#   jobsub_submit_systematics.sh <systematics_toml> <merged_input_file> [branch] [output_dir]
#
# Arguments:
#   <systematics_toml>   - local path to the systematics TOML (e.g. NuMI_nue_gundam.toml)
#   <merged_input_file>  - PNFS or xrootd path to the merged selection ROOT file
#   [branch]             - medulla git branch (default: develop)
#   [output_dir]         - remote output directory
#                          (default: /pnfs/icarus/scratch/users/$USER/medulla_systematics/)
#
# The job rewrites [input] path and [output] path in the TOML automatically,
# so the paths in the TOML do not need to be updated before submission.
# The weights path is left unchanged and must be accessible from the grid node.

SYS_TOML="${1:?Usage: $0 <systematics_toml> <merged_input_file> [branch] [output_dir]}"
INPUT_FILE="${2:?Usage: $0 <systematics_toml> <merged_input_file> [branch] [output_dir]}"
BRANCH="${3:-develop}"
OUTDIR="${4:-/pnfs/icarus/scratch/users/${USER}/medulla_systematics/}"
GROUP="${GROUP:-icarus}"
ROLE="${ROLE:-Analysis}"
IMAGE="${IMAGE:-/cvmfs/singularity.opensciencegrid.org/fermilab/fnal-wn-sl7:latest}"

SYS_TOML_ABS="$(realpath "$SYS_TOML")"
SYS_TOML_BASENAME="$(basename "$SYS_TOML_ABS")"
SYS_TOML_DIR="$(dirname "$SYS_TOML_ABS")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ABS="$SCRIPT_DIR/run_systematics_only.sh"

if [[ ! -f "$RUNNER_ABS" ]]; then
  echo "[ERROR] Missing runner script: $RUNNER_ABS"
  exit 2
fi
chmod +x "$RUNNER_ABS"

if [[ ! -f "$SYS_TOML_ABS" ]]; then
  echo "[ERROR] Systematics TOML not found: $SYS_TOML_ABS"
  exit 2
fi

if [[ ! -d "$OUTDIR" ]]; then
  echo "[INFO] Creating output directory: $OUTDIR"
  mkdir -p "$OUTDIR"
fi

export MEDULLA_BRANCH="$BRANCH"
export MEDULLA_OUTPUT_DIR="$OUTDIR"
export MEDULLA_SYS_TOML="$SYS_TOML_BASENAME"
export INPUT_FILE="$INPUT_FILE"

# Bundle the systematics TOML for dropbox upload (mounted via CVMFS in the job)
TAR_TOML="sysonly_toml.tar.gz"
echo "[INFO] Bundling systematics TOML: $SYS_TOML_ABS"
tar czf "$TAR_TOML" -C "$SYS_TOML_DIR" "$SYS_TOML_BASENAME"

echo "[INFO] Submitting systematics-only job"
echo "[INFO]   TOML:   $SYS_TOML_ABS"
echo "[INFO]   Input:  $INPUT_FILE"
echo "[INFO]   Branch: $BRANCH"
echo "[INFO]   Output: $OUTDIR"

SOURCE_DIR="$(pwd)"

jobsub_submit \
  -G "$GROUP" \
  --role="$ROLE" \
  -N 1 \
  --cpu=1 \
  --memory=8000MB \
  --disk=80GB \
  --resource-provides=usage_model=DEDICATED,OPPORTUNISTIC,OFFSITE \
  -l +SingularityImage="$IMAGE" \
  --append_condor_requirements='(TARGET.HAS_Singularity==true)' \
  -e MEDULLA_BRANCH \
  -e MEDULLA_OUTPUT_DIR \
  -e MEDULLA_SYS_TOML \
  -e INPUT_FILE \
  -e IFDH_CP_MAXRETRIES=4 \
  -e IFDH_CP_UNLINK_ON_ERROR=2 \
  --site=FermiGrid \
  --lines '+FERMIHTC_AutoRelease=True' \
  --lines '+FERMIHTC_GraceMemory=4096' \
  --lines '+FERMIHTC_GraceLifetime=3600' \
  --tar_file_name "dropbox://${SOURCE_DIR}/${TAR_TOML}" \
  --use-cvmfs-dropbox \
  "file://$RUNNER_ABS"

rm -f "$TAR_TOML"

echo "[INFO] Systematics job submitted successfully"
echo "[INFO] Output will appear at: $OUTDIR/output_sys.root"
echo "[INFO] Logs will appear at:   $OUTDIR/logs/"
