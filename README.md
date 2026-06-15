# Grid Search - Selection Optimization

This directory contains tools for optimizing event selection criteria using Optuna, a hyperparameter optimization framework. The optimization is designed to handle large ROOT datasets efficiently through batch processing.

## Overview

The `gridSearch` package performs automated selection optimization on particle physics data by:

- **Batched Optimization**: Iterates through large ROOT files in memory-efficient chunks (200 MB default) to evaluate multiple trials per pass
- **Flexible Metrics**: Supports multiple optimization metrics including:
  - **Sensitivity**: Signal significance (s/√(b+1))
  - **Purity**: True signal fraction (signal/selected)
  - **Efficiency**: Signal detection rate (signal/total_signal)
  - **F1 Score**: Harmonic mean of precision and recall
- **Parameter Search**: Optimizes over continuous (float) and categorical parameters
- **Result Tracking**: Logs all trials and results to an SQLite database for reproducibility and analysis

## File Structure

- `gridSearch.py` - Main optimization framework and `gridSearch` class
- `medulla_grid.py` - Integration with Medulla analysis framework
- `parameters.yaml` - Configuration file defining optimization parameters and ranges
- `medulla_parameters.yaml` - Alternative configuration for Medulla-based optimization
- `nueCC_inclusive.toml` - Selection criteria configuration
- `analyze/` - Post-optimization analysis scripts
- `condor/` - Condor batch submission scripts
- `generated_medulla_tomls/` - Output directory for generated TOML files

## Installation & Setup

### Prerequisites
```bash
pip install optuna uproot awkward pyyaml numpy
```

ROOT must be available in your Python environment.

### Configuration

Edit `parameters.yaml` to define your optimization parameters. Each parameter should specify:

```yaml
parameters:
  param_name:
    type: 'float' or 'categorical'
    branch: 'branch_name_in_root_file'
    operator: '>', '<', '==', '>=', '<=', '!='
    range: [min, max]  # for float: [lower_bound, upper_bound]
             # for categorical: [option1, option2, ...]
```

**Example:**
```yaml
parameters:
  shower_density_cut:
    type: 'float'
    branch: 'rShowerDensity'
    operator: '>'
    range: [0.0, 1.0]
  fiducial_cut:
    type: 'float'
    branch: 'rFiducial'
    operator: '>'
    range: [0.0, 1000.0]
```

## Basic Usage

### Simple Optimization Run

```python
from gridSearch import gridSearch

# Initialize with ROOT file(s) - specify tree path with ':'
files = ["path/to/data.root:tree_name/tree_name"]
mySearch = gridSearch(fileList=files)

# Load configuration
mySearch.setup()

# Run optimization
mySearch.run_batched_demo()

# Results will be stored in: optuna_test.db
```

### Using with Medulla Framework

```python
from medulla_grid import MedullaGridSearch

mySearch = MedullaGridSearch(fileList=files)
mySearch.setup()
mySearch.run_optimization(n_trials=100)
```

## Advanced Features

### Custom Optimization Configuration

```python
study = optuna.create_study(
    direction='maximize',  # or 'minimize'
    study_name='my_study',
    storage='sqlite:///custom_path.db',
    load_if_exists=True  # Resume previous optimization
)

mySearch.batched_optimize(
    study=study,
    n_trials=100,
    trials_per_pass=10  # Batch size (adjust based on memory)
)
```

### Custom Metrics

Modify the `getMetric()` method in `gridSearch.py` to implement custom evaluation metrics. The method receives:
- `true_selected` - Count of true signal events selected
- `selected` - Total count of selected events
- `total` - Total events in dataset
- `total_signal` - Total true signal events

## Database & Results

Optimization results are stored in SQLite format. Access results with:

```python
import optuna

study = optuna.load_study(
    study_name='batched_demo',
    storage='sqlite:///optuna_test.db'
)

print('Best parameters:', study.best_params)
print('Best score:', study.best_value)

# Export trials to DataFrame
df = study.trials_dataframe()
df.to_csv('optimization_results.csv')
```

## Performance Tips

1. **Batch Size**: Adjust `trials_per_pass` based on available memory. Larger values = fewer file iterations but more memory usage
2. **Data Size**: Use step_size in uproot.iterate() (default 200 MB) to control per-iteration memory
3. **Parallel Trials**: For faster optimization, use Optuna's sampler options (e.g., `TPESampler`)
4. **Resume**: Always use `load_if_exists=True` to continue previous runs

## Troubleshooting

- **Memory Issues**: Reduce `trials_per_pass` or decrease `step_size` in uproot.iterate()
- **Missing Branches**: Verify branch names match exactly in ROOT files and `parameters.yaml`
- **No Improvement**: Check that signal definition (e.g., `tNeutrinoType == 2`) matches your data

## Example Workflow

```bash
# 1. Prepare your data (e.g., convert to ROOT with needed branches)
# 2. Create parameters.yaml with your optimization space
# 3. Run optimization
python gridSearch.py
# 4. Analyze results
python analyze/plot_study.py optuna_test.db
```

## References

- [Optuna Documentation](https://optuna.readthedocs.io/)
- [Uproot Documentation](https://uproot.readthedocs.io/)
- [Awkward Array Documentation](https://awkward-array.org/)
