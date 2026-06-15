#!/bin/bash
set -euo pipefail

# Submit one cluster for all configs listed in jobs.txt.
# Uploads all TOML configs to jobsub dropbox, which mounts them via /cvmfs
# at ${INPUT_TAR_DIR_LOCAL} (available to all jobs without per-file transfer).
#
# Run this from gridSearch/generated_medulla_tomls.
# Usage: ../condor/jobsub_submit_jobs.sh <branch> [output_dir]

BRANCH="${1:-feature/carriganm95_working}"
OUTDIR="${2:-/pnfs/icarus/scratch/users/${USER}/medulla_selection/}"
GROUP="${GROUP:-icarus}"
ROLE="${ROLE:-Analysis}"
IMAGE="${IMAGE:-/cvmfs/singularity.opensciencegrid.org/fermilab/fnal-wn-sl7:latest}"

# Export runtime variables for the worker script; pass them through with -e.
export MEDULLA_CFG_MODE="__FROM_JOBS_TXT__"
export MEDULLA_BRANCH="$BRANCH"
export MEDULLA_OUTPUT_DIR="$OUTDIR"
export INPUT_FILE="${3:-root://fndcadoor.fnal.gov://icarus/persistent/users/dcarber/spine/combined_files/NuMI_CV_flat_cafs_2/NuMI_CV_flat_cafs_2_01.root}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ABS="$SCRIPT_DIR/run_medulla_selection.sh"
SOURCE_DIR="$(pwd)"

nJobs=$(wc -l < jobs.txt)

if [[ ! -d "$OUTDIR" ]]; then
  echo "[INFO] Output directory does not exist, creating: $OUTDIR"
  mkdir -p "$OUTDIR"
fi

if [[ ! -d "$OUTDIR/logs" ]]; then
  echo "[INFO] Creating logs subdirectory in output directory: $OUTDIR/logs"
  mkdir -p "$OUTDIR/logs"
fi

# Create subdirectories for outputs and logs (groups of 100 jobs)
for ((i=0; i<$((($nJobs + 99) / 100)); i++)); do
    subdir=$(printf "%02d" $i)
    if [ ! -d $MEDULLA_OUTPUT_DIR/outputs/$subdir ]; then
        mkdir -p $MEDULLA_OUTPUT_DIR/outputs/$subdir
    fi
    if [ ! -d $MEDULLA_OUTPUT_DIR/logs/$subdir ]; then
        mkdir -p $MEDULLA_OUTPUT_DIR/logs/$subdir
    fi
done


if [[ ! -f jobs.txt ]]; then
  echo "[ERROR] jobs.txt not found in $(pwd)"
  echo "[HINT] cd gridSearch/generated_medulla_tomls first"
  exit 2
fi

if [[ ! -f "$RUNNER_ABS" ]]; then
  echo "[ERROR] Missing wrapper script: $RUNNER_ABS"
  exit 2
fi

if [[ ! -x "$RUNNER_ABS" ]]; then
  chmod +x "$RUNNER_ABS"
fi

# Read all TOML filenames from jobs.txt
mapfile -t cfgs < <(grep -v '^\s*$' jobs.txt)
if [[ ${#cfgs[@]} -eq 0 ]]; then
  echo "[ERROR] jobs.txt is empty"
  exit 2
fi

# Verify all TOMLs exist locally
for cfg in "${cfgs[@]}"; do
  if [[ ! -f "$cfg" ]]; then
    echo "[ERROR] Missing config listed in jobs.txt: $cfg"
    exit 2
  fi
done

echo "[INFO] Submitting ${#cfgs[@]} job(s) in one jobsub_submit call"
echo "[INFO] Output directory: $OUTDIR"

# Create a tarball of all TOMLs to upload to dropbox (will be mounted via /cvmfs)
TAR_TOMLS="tomls_bundle.tar.gz"
echo "[INFO] Creating tarball of ${#cfgs[@]} TOML files: $TAR_TOMLS"
tar czf "$TAR_TOMLS" "${cfgs[@]}" jobs.txt

echo "[INFO] Transferring files:"
echo "  - $RUNNER_ABS (wrapper script)"
echo "  - $TAR_TOMLS (TOML bundle via dropbox/CVMFS)"

echo "[INFO] Running jobsub_submit"
jobsub_submit \
  -G "$GROUP" \
  --role="$ROLE" \
  -N "${#cfgs[@]}" \
  --cpu=1 \
  --memory=2000MB \
  --disk=80GB \
  --resource-provides=usage_model=DEDICATED,OPPORTUNISTIC,OFFSITE \
  -l +SingularityImage="$IMAGE" \
  --append_condor_requirements='(TARGET.HAS_Singularity==true)' \
  -e MEDULLA_CFG_MODE \
  -e MEDULLA_BRANCH \
  -e MEDULLA_OUTPUT_DIR \
  -e IFDH_CP_MAXRETRIES=4 \
  -e IFDH_CP_UNLINK_ON_ERROR=2 \
  -e INPUT_FILE \
  --site=FermiGrid \
  --lines '+FERMIHTC_AutoRelease=True' \
  --lines '+FERMIHTC_GraceMemory=4096' \
  --lines '+FERMIHTC_GraceLifetime=3600' \
  -d OUT "$OUTDIR" \
  --tar_file_name "dropbox://${SOURCE_DIR}/${TAR_TOMLS}" \
  --use-cvmfs-dropbox \
  "file://$RUNNER_ABS"

# Clean up tarball after submission
rm -f "$TAR_TOMLS"

echo "[INFO] Job cluster submitted successfully"
