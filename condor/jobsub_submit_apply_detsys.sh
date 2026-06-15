#!/bin/bash
set -euo pipefail

# Submit N phase-2 detsys weight-application jobs, one per per-job selection file.
# Run this after:
#   1. All selection jobs are complete
#   2. mergeFiles.sh has produced a merged file
#   3. A phase-1 variation systematics job has produced a splines file
#
# Usage:
#   jobsub_submit_apply_detsys.sh <detsys_toml> <splines_file> <input_list> \
#                                 [branch] [output_dir]
#
# Arguments:
#   <detsys_toml>   - local path to the apply-detsys TOML (NuMI_nue_apply_detsys.toml)
#   <splines_file>  - PNFS or xrootd path to the phase-1 splines ROOT file
#   <input_list>    - text file listing one per-job selection ROOT file per line
#                     (PNFS or xrootd paths); one job is submitted per line
#   [branch]        - medulla git branch (default: develop)
#   [output_dir]    - remote output directory
#                     (default: /pnfs/icarus/scratch/users/$USER/medulla_detsys/)

DETSYS_TOML="${1:?Usage: $0 <detsys_toml> <splines_file> <input_list> [branch] [output_dir]}"
SPLINES_FILE="${2:?Usage: $0 <detsys_toml> <splines_file> <input_list> [branch] [output_dir]}"
INPUT_LIST="${3:?Usage: $0 <detsys_toml> <splines_file> <input_list> [branch] [output_dir]}"
BRANCH="${4:-develop}"
OUTDIR="${5:-/pnfs/icarus/scratch/users/${USER}/medulla_detsys/}"
GROUP="${GROUP:-icarus}"
ROLE="${ROLE:-Analysis}"
IMAGE="${IMAGE:-/cvmfs/singularity.opensciencegrid.org/fermilab/fnal-wn-sl7:latest}"

DETSYS_TOML_ABS="$(realpath "$DETSYS_TOML")"
DETSYS_TOML_BASENAME="$(basename "$DETSYS_TOML_ABS")"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ABS="$SCRIPT_DIR/run_apply_detsys.sh"

if [[ ! -f "$RUNNER_ABS" ]]; then
  echo "[ERROR] Runner not found: $RUNNER_ABS"
  exit 2
fi
chmod +x "$RUNNER_ABS"

if [[ ! -f "$DETSYS_TOML_ABS" ]]; then
  echo "[ERROR] TOML not found: $DETSYS_TOML_ABS"
  exit 2
fi

if [[ ! -f "$INPUT_LIST" ]]; then
  echo "[ERROR] Input list not found: $INPUT_LIST"
  exit 2
fi

# Count and validate input files
mapfile -t input_files < <(grep -v '^\s*$' "$INPUT_LIST")
nJobs=${#input_files[@]}
if [[ $nJobs -eq 0 ]]; then
  echo "[ERROR] Input list is empty: $INPUT_LIST"
  exit 2
fi
echo "[INFO] Found $nJobs input files in $INPUT_LIST"

if [[ ! -d "$OUTDIR" ]]; then
  echo "[INFO] Creating output directory: $OUTDIR"
  mkdir -p "$OUTDIR"
fi

# Create output/logs subdirectories grouped by 100 jobs
for ((i=0; i<$(( (nJobs + 99) / 100 )); i++)); do
  subdir=$(printf "%02d" $i)
  mkdir -p "$OUTDIR/outputs/$subdir"
  mkdir -p "$OUTDIR/logs/$subdir"
done

# Write an inputs.txt into the dropbox bundle so each job can read its file
# using PROCESS as the line index (matching jobs.txt convention).
printf '%s\n' "${input_files[@]}" > inputs.txt

export MEDULLA_BRANCH="$BRANCH"
export MEDULLA_OUTPUT_DIR="$OUTDIR"
export MEDULLA_DETSYS_TOML="$DETSYS_TOML_BASENAME"
export SPLINES_FILE="$SPLINES_FILE"
# INPUT_FILE is resolved per-job from inputs.txt inside the runner via PROCESS.
# We pass inputs.txt in the tarball and use a small wrapper; see note below.

# Bundle the TOML and inputs.txt into the dropbox tarball.
TAR="apply_detsys_bundle.tar.gz"
echo "[INFO] Bundling $DETSYS_TOML_BASENAME + inputs.txt -> $TAR"
cp "$DETSYS_TOML_ABS" "$DETSYS_TOML_BASENAME"
tar czf "$TAR" "$DETSYS_TOML_BASENAME" inputs.txt
rm -f "$DETSYS_TOML_BASENAME"

# The runner reads INPUT_FILE from the environment. We resolve it per-job by
# passing MEDULLA_INPUT_LIST_MODE and letting the runner pick its line from
# inputs.txt using $PROCESS. We export a sentinel so the runner knows to read
# from the list rather than a fixed INPUT_FILE.
export INPUT_FILE="__FROM_INPUTS_TXT__"

echo "[INFO] Submitting $nJobs phase-2 detsys jobs"
echo "[INFO]   TOML:        $DETSYS_TOML_ABS"
echo "[INFO]   Splines:     $SPLINES_FILE"
echo "[INFO]   Input list:  $INPUT_LIST ($nJobs files)"
echo "[INFO]   Branch:      $BRANCH"
echo "[INFO]   Output:      $OUTDIR"

SOURCE_DIR="$(pwd)"

jobsub_submit \
  -G "$GROUP" \
  --role="$ROLE" \
  -N "$nJobs" \
  --cpu=1 \
  --memory=4000MB \
  --disk=80GB \
  --resource-provides=usage_model=DEDICATED,OPPORTUNISTIC,OFFSITE \
  -l +SingularityImage="$IMAGE" \
  --append_condor_requirements='(TARGET.HAS_Singularity==true)' \
  -e MEDULLA_BRANCH \
  -e MEDULLA_OUTPUT_DIR \
  -e MEDULLA_DETSYS_TOML \
  -e SPLINES_FILE \
  -e INPUT_FILE \
  -e IFDH_CP_MAXRETRIES=4 \
  -e IFDH_CP_UNLINK_ON_ERROR=2 \
  --site=FermiGrid \
  --lines '+FERMIHTC_AutoRelease=True' \
  --lines '+FERMIHTC_GraceMemory=4096' \
  --lines '+FERMIHTC_GraceLifetime=3600' \
  --tar_file_name "dropbox://${SOURCE_DIR}/${TAR}" \
  --use-cvmfs-dropbox \
  "file://$RUNNER_ABS"

rm -f "$TAR" inputs.txt

echo "[INFO] Phase-2 detsys cluster submitted ($nJobs jobs)"
echo "[INFO] Outputs: $OUTDIR/outputs/XX/output_detsys_<N>.root"
echo "[INFO] Logs:    $OUTDIR/logs/XX/detsys_<N>.{out,err}"
