#!/usr/bin/env python3
"""Generate Medulla selection TOMLs with varied cut thresholds.

This is intentionally *Medulla-native*: it edits only the `[parameters]` block
of an existing Medulla selection TOML (e.g. `medulla/selection/toml/nueCC_inclusive.toml`)
so that:
  - the rest of the TOML (trees/samples/branches/cuts/comments) stays identical
  - each output TOML can be run as a standalone Medulla selection job

Typical usage
-------------

1) Copy and edit the parameter-space file:
   gridSearch/medulla_parameters.example.yaml

2) Generate N TOMLs:
   python gridSearch/medulla_grid.py generate \
     --base medulla/selection/toml/nueCC_inclusive.toml \
     --params gridSearch/medulla_parameters.example.yaml \
     --outdir gridSearch/generated_medulla_tomls \
     --n 50 --seed 1

This writes:
  - gridSearch/generated_medulla_tomls/*.toml
  - gridSearch/generated_medulla_tomls/jobs.txt
  - gridSearch/generated_medulla_tomls/params.csv
"""

from __future__ import annotations

import argparse
import csv
import itertools
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple

import numpy as np
import yaml


_SECTION_RE = re.compile(r"^\s*\[(?P<name>[^\]]+)\]\s*$")


@dataclass(frozen=True)
class ParamSpec:
    name: str
    ptype: str
    mode: str
    range: Optional[Tuple[float, float]] = None
    values: Optional[List[Any]] = None
    n: Optional[int] = None


def _toml_scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    if isinstance(value, float):
        # Use a stable representation; Medulla TOMLs generally use decimals.
        # repr() avoids too many trailing zeros.
        return repr(float(value))
    if isinstance(value, str):
        escaped = value.replace('"', '\\"')
        return f'"{escaped}"'
    raise TypeError(f"Unsupported TOML scalar type: {type(value)}")


def load_param_specs(path: Path, mode_override: Optional[str]) -> List[ParamSpec]:
    doc = yaml.safe_load(path.read_text())
    if not isinstance(doc, dict) or 'parameters' not in doc:
        raise ValueError("YAML must contain a top-level 'parameters' mapping")

    specs: List[ParamSpec] = []
    for name, raw in doc['parameters'].items():
        if not isinstance(raw, dict):
            raise ValueError(f"Parameter '{name}' must map to a dict")
        ptype = str(raw.get('type', 'float')).lower()
        mode = str(raw.get('mode', 'random')).lower()
        if mode_override:
            mode = mode_override


        rng = raw.get('range')
        values = raw.get('values')
        n = raw.get('n')

        if ptype in ('float', 'int'):
            has_range = isinstance(rng, (list, tuple)) and len(rng) == 2
            has_values = isinstance(values, list) and len(values) > 0

            if mode == 'grid' and has_values:
                specs.append(ParamSpec(name=name, ptype=ptype, mode=mode, values=values))
            else:
                if not has_range:
                    raise ValueError(
                        f"Parameter '{name}' of type {ptype} must have range: [min, max] "
                        "(or provide non-empty values in grid mode)"
                    )
                r0, r1 = float(rng[0]), float(rng[1])
                if mode == 'grid' and (n is None or int(n) <= 0):
                    raise ValueError(f"Parameter '{name}' in grid mode must define positive integer 'n'")
                specs.append(
                    ParamSpec(
                        name=name,
                        ptype=ptype,
                        mode=mode,
                        range=(r0, r1),
                        n=(int(n) if n is not None else None),
                    )
                )
        elif ptype == 'categorical':
            if not isinstance(values, list) or len(values) == 0:
                raise ValueError(f"Parameter '{name}' categorical must have non-empty values: [...] ")
            specs.append(ParamSpec(name=name, ptype=ptype, mode=mode, values=values))
        else:
            raise ValueError(f"Unsupported type for parameter '{name}': {ptype}")

    if len(specs) == 0:
        raise ValueError("No parameters defined")
    return specs


def iter_param_points(
    specs: List[ParamSpec],
    n: int,
    seed: int,
    max_jobs: Optional[int],
) -> Iterable[Dict[str, Any]]:
    rng = np.random.default_rng(seed)

    grid_specs = [s for s in specs if s.mode == 'grid']
    rand_specs = [s for s in specs if s.mode != 'grid']

    grid_axes: List[Tuple[str, List[Any]]] = []
    for s in grid_specs:
        # In grid mode, explicit values are treated as fixed grid points.
        if isinstance(s.values, list) and len(s.values) > 0:
            vals = list(s.values)
        elif s.ptype == 'int':
            if s.range is None:
                raise ValueError(f"grid int '{s.name}' needs either values or range")
            # Inclusive integer grid
            lo, hi = int(round(s.range[0])), int(round(s.range[1]))
            if s.n is None:
                raise ValueError(f"grid int '{s.name}' needs n")
            if s.n == 1:
                vals = [lo]
            else:
                vals = np.linspace(lo, hi, s.n)
                vals = [int(round(v)) for v in vals]
                # de-duplicate if rounding collapsed points
                vals = list(dict.fromkeys(vals))
        elif s.ptype == 'float':
            if s.range is None:
                raise ValueError(f"grid float '{s.name}' needs either values or range")
            if s.n is None:
                raise ValueError(f"grid float '{s.name}' needs n")
            lo, hi = float(s.range[0]), float(s.range[1])
            vals = list(np.linspace(lo, hi, s.n))
        elif s.ptype == 'categorical':
            # Defensive check for malformed categorical grid specs.
            raise ValueError(f"grid categorical '{s.name}' needs non-empty values")
        else:
            raise ValueError(f"Unsupported grid type for '{s.name}': {s.ptype}")
        grid_axes.append((s.name, vals))

    def sample_one(spec: ParamSpec) -> Any:
        if spec.ptype == 'categorical':
            assert spec.values is not None
            return spec.values[int(rng.integers(0, len(spec.values)))]
        assert spec.range is not None
        lo, hi = spec.range
        if spec.ptype == 'int':
            return int(rng.integers(int(np.floor(lo)), int(np.floor(hi)) + 1))
        return float(rng.uniform(lo, hi))

    # If we have any grid axes, enumerate the product (then cap/shuffle).
    if grid_axes:
        keys = [k for k, _ in grid_axes]
        values_lists = [v for _, v in grid_axes]
        combos = list(itertools.product(*values_lists))
        rng.shuffle(combos)
        if max_jobs is not None:
            combos = combos[: max_jobs]

        for combo in combos:
            point: Dict[str, Any] = dict(zip(keys, combo))
            for s in rand_specs:
                point[s.name] = sample_one(s)
            yield point
        return

    # Pure random.
    count = n
    if max_jobs is not None:
        count = min(count, max_jobs)
    for _ in range(count):
        point = {s.name: sample_one(s) for s in specs}
        yield point


def patch_parameters_block(base_text: str, updates: Dict[str, Any], header_comment: Optional[str]) -> str:
    lines = base_text.splitlines(keepends=True)

    start = None
    end = None
    for i, line in enumerate(lines):
        m = _SECTION_RE.match(line)
        if not m:
            continue
        if m.group('name').strip() == 'parameters':
            start = i
            continue
        if start is not None:
            end = i
            break

    if start is None:
        raise ValueError("Base TOML has no [parameters] section")
    if end is None:
        end = len(lines)

    # Build a map of existing key->line index inside parameters section.
    key_to_idx: Dict[str, int] = {}
    assign_re = re.compile(r"^\s*(?P<key>[A-Za-z0-9_]+)\s*=\s*(?P<val>.+?)\s*$")
    for i in range(start + 1, end):
        m = assign_re.match(lines[i])
        if m:
            key_to_idx[m.group('key')] = i

    # Optional comment inserted immediately after [parameters]
    insert_at = start + 1
    if header_comment:
        comment_line = f"# {header_comment}\n"
        # Only insert if not already present right below.
        if insert_at < len(lines) and lines[insert_at].startswith('#') and header_comment in lines[insert_at]:
            pass
        else:
            lines.insert(insert_at, comment_line)
            # Keep indices consistent: end shifts by +1
            end += 1
            # Shift existing indices
            key_to_idx = {k: (idx + 1 if idx >= insert_at else idx) for k, idx in key_to_idx.items()}

    # Apply updates
    for key, val in updates.items():
        new_line = f"{key} = {_toml_scalar(val)}\n"
        if key in key_to_idx:
            lines[key_to_idx[key]] = new_line
        else:
            # append before end of [parameters] section
            lines.insert(end, new_line)
            end += 1

    return ''.join(lines)


def patch_cut_blocks_remove_params(base_text: str, param_names: Iterable[str]) -> str:
    """
    Remove entries from every TOML ``cut = [ ... ]`` block if a line references
    any parameter token ``@<param>`` where ``<param>`` is in ``param_names``.

    This enables turning off a cut by setting its steering parameter to
    ``null``/``None`` in the parameter-space YAML.
    """
    names = [str(p) for p in param_names if p is not None]
    if len(names) == 0:
        return base_text

    tokens = [f"@{n}" for n in names]
    lines = base_text.splitlines(keepends=True)

    out: List[str] = []
    in_cut_block = False

    for line in lines:
        if not in_cut_block and re.match(r"^\s*cut\s*=\s*\[\s*$", line):
            in_cut_block = True
            out.append(line)
            continue

        if in_cut_block:
            if re.match(r"^\s*\]\s*$", line):
                in_cut_block = False
                out.append(line)
                continue

            # Remove any cut-object line that depends on a disabled parameter.
            if any(tok in line for tok in tokens):
                continue

            out.append(line)
            continue

        out.append(line)

    return ''.join(out)


def patch_general_output(base_text: str, new_output: str) -> str:
    lines = base_text.splitlines(keepends=True)
    start = None
    end = None
    for i, line in enumerate(lines):
        m = _SECTION_RE.match(line)
        if not m:
            continue
        if m.group('name').strip() == 'general':
            start = i
            continue
        if start is not None:
            end = i
            break
    if start is None:
        return base_text
    if end is None:
        end = len(lines)

    assign_re = re.compile(r"^\s*output\s*=\s*(?P<val>.+?)\s*$")
    for i in range(start + 1, end):
        m = assign_re.match(lines[i])
        if m:
            lines[i] = f"output = {_toml_scalar(new_output)}\n"
            return ''.join(lines)

    # If no output key existed, insert one right after [general]
    lines.insert(start + 1, f"output = {_toml_scalar(new_output)}\n")
    return ''.join(lines)
def cmd_generate(args: argparse.Namespace) -> None:
    base_path = Path(args.base)
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    specs = load_param_specs(Path(args.params), mode_override=args.mode)

    base_text = base_path.read_text()
    base_stem = base_path.stem

    jobs_txt = outdir / 'jobs.txt'
    params_csv = outdir / 'params.csv'

    points = list(iter_param_points(specs, n=args.n, seed=args.seed, max_jobs=args.max_jobs))
    if len(points) == 0:
        raise ValueError("No points generated; check your parameter spec")

    # Write TOMLs
    toml_paths: List[Path] = []
    for jobid, point in enumerate(points):
        clean_point = {k: (float(v) if isinstance(v, (np.floating, float)) else (int(v) if isinstance(v, (np.integer, int)) and not isinstance(v, bool) else v)) for k, v in point.items()}
        header = f"generated by medulla_grid.py; jobid={jobid}; seed={args.seed}; params={clean_point}"
        # Parameters explicitly set to null/None disable corresponding cuts.
        # TOML has no null scalar, so we do not write these into [parameters].
        disabled_params = {k for k, v in point.items() if v is None}
        param_updates = {k: v for k, v in point.items() if v is not None}

        patched = patch_parameters_block(base_text, param_updates, header_comment=header)
        if disabled_params:
            patched = patch_cut_blocks_remove_params(patched, disabled_params)

        if args.set_output is not None:
            patched = patch_general_output(patched, args.set_output)
        out_path = outdir / f"{base_stem}__job{jobid:04d}.toml"
        out_path.write_text(patched)
        toml_paths.append(out_path)

    # Write jobs list
    # Write relative names so Condor can use initialdir=outdir and transfer_input_files=$(CONFIG)
    jobs_txt.write_text('\n'.join(p.name for p in toml_paths) + '\n')

    # Write params.csv (jobid + columns in spec order)
    fieldnames = ['jobid'] + [s.name for s in specs]
    with params_csv.open('w', newline='') as f:
        w = csv.DictWriter(f, fieldnames=fieldnames)
        w.writeheader()
        for jobid, point in enumerate(points):
            row = {'jobid': jobid}
            row.update({k: point.get(k) for k in fieldnames[1:]})
            w.writerow(row)

    print(f"[OK] Wrote {len(toml_paths)} TOML(s) to {outdir}")
    print(f"[OK] jobs list: {jobs_txt}")
    print(f"[OK] params table: {params_csv}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='cmd', required=True)

    g = sub.add_parser('generate', help='Generate per-job Medulla selection TOMLs')
    g.add_argument('--base', required=True, help='Base Medulla selection TOML (input)')
    g.add_argument('--params', required=True, help='YAML parameter-space file')
    g.add_argument('--outdir', required=True, help='Output directory for generated TOMLs')
    g.add_argument('--n', type=int, default=50, help='Number of random points (ignored if using any grid params)')
    g.add_argument('--seed', type=int, default=1, help='RNG seed')
    g.add_argument('--mode', choices=['random', 'grid'], default=None, help='Override per-parameter mode')
    g.add_argument('--max-jobs', type=int, default=None, help='Cap number of TOMLs written (useful for large grids)')
    g.add_argument('--set-output', default=None, help='If set, overwrite [general].output to this string (useful for batch jobs expecting output.root)')
    g.set_defaults(func=cmd_generate)

    args = p.parse_args()
    args.func(args)


if __name__ == '__main__':
    main()
