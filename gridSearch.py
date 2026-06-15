import ROOT as r
import numpy as np
import uproot
import array as arr
import optuna
import awkward as ak
from optuna.distributions import FloatDistribution, CategoricalDistribution
from typing import Dict, List, Tuple
import os, sys
import yaml

'''
This file defines the gridSearch class which performs selection optimization using Optuna. Optimization is done in batches to handle large datasets efficiently. 
For N trials there are M trials run in each pass, iterating over the data in chunks. This is achieved through one iteration through uproot per M trials.
The evaluation metric can be customized and each trial is logged to an sqlite database.
'''


# Main grid search class
class gridSearch():

    def __init__(self, fileList, branches=None):
        self.pars = []
        self.fileList = fileList
        self.branches = branches if branches is not None else []

    # Load YAML configuration 
    def load_yaml(self, path):
        with open(path, 'r') as f:
            return yaml.safe_load(f)

    # Creates a boolean mask based on selection criteria
    def apply_selection_fast(self, batch, selection_criteria: Dict[str, Tuple[str, float]]):
        cut = None
        for key, expr in selection_criteria.items():
            op_, thr = expr
            arr = batch[key]
            if op_ == '>':
                cur = arr > thr
            elif op_ == '<':
                cur = arr < thr
            elif op_ == '==':
                cur = arr == thr
            elif op_ == '>=':
                cur = arr >= thr
            elif op_ == '<=':
                cur = arr <= thr
            elif op_ == '!=':
                cur = arr != thr
            else:
                raise ValueError(f"Unsupported operation: {op_}")
            cut = cur if cut is None else (cut & cur)
        return cut

    #construct selection criteria from parameters and optuna trial chosen values
    def build_selection_criteria(self, params):
        criteria = {}
        for p in self.pars:
            criteria[p.branch] = (p.operator, float(params[p.name]))
        return criteria

    # Compute evaluation metric
    def getMetric(self, true_selected, selected, total, total_signal, metric='sensitivity'):

        s = true_selected
        b = selected - true_selected
        totSel = selected

        if metric == 'sensitivity':
            return s/np.sqrt(b+1)
        elif metric == "purity":
            return s/totSel
        elif metric == "efficiency":
            return s / total_signal
        elif metric == "f1":
            TP = s
            FP = b
            FN = total_signal - TP
            TN = total - (FP + FN + TP)
            return 2*TP / (2*TP + FP + FN)
        else:
            raise ValueError(f"Unsupported metric: {metric}")

    # Evaluate multiple trials on a single batch
    def eval_trials_on_batch(self, batch, trials_params_list):
        selected, true_selected = [], []

        #use tNeutrinoType to count total events and total signal events
        total_events = ak.count(batch['tNeutrinoType'])
        total_signal = ak.sum(batch['tNeutrinoType'] == 2)

        # Evaluate each sub trial
        for params in trials_params_list:
            criteria = self.build_selection_criteria(params)
            mask = self.apply_selection_fast(batch, criteria)
            total_selected_ = ak.count(batch['tNeutrinoType'][mask])
            true_selected_ = ak.sum(batch['tNeutrinoType'][mask] == 2)
            selected.append(total_selected_)
            true_selected.append(true_selected_)
        return np.array(selected, dtype=float), np.array(true_selected, dtype=float), total_events, total_signal

    # Run optimization in batches
    def batched_optimize(self, study, n_trials: int, trials_per_pass: int = 10):

        remaining = n_trials
        while remaining > 0:
            print(f"Trials remaining: {remaining}/{n_trials}")
            k = min(trials_per_pass, remaining)
            distributions = {p.name: p.distribution for p in self.pars}
            trials = [study.ask(distributions) for _ in range(k)]
            params_list = [t.params for t in trials]

            selected_sum = np.zeros(k, dtype=float)
            true_selected_sum = np.zeros(k, dtype=float)
            total_sum = 0
            total_signal_sum = 0

            for ib, batch in enumerate(uproot.iterate(files, branches, step_size='200 MB')):
                batch_selected, batch_true_selected, batch_total, batch_signal = self.eval_trials_on_batch(batch, params_list)
                selected_sum += batch_selected
                true_selected_sum += batch_true_selected
                total_sum += batch_total
                total_signal_sum += batch_signal

            scores = selected_sum / total_sum if total_sum > 0 else np.zeros_like(selected_sum)
            scores = [self.getMetric(ts, s, total_sum, total_signal_sum) for ts, s in zip(true_selected_sum, selected_sum)]
            for t, sc in zip(trials, scores):
                study.tell(t, float(sc))

            remaining -= k

    # Start the optimization
    def run_batched_demo(self):
        study = optuna.create_study(direction='maximize', 
                                    study_name='batched_demo', 
                                    storage='sqlite:////nashome/m/micarrig/icarus/NuE/gridSearch/optuna_test.db',
                                    load_if_exists=True)
        self.batched_optimize(study, n_trials=100, trials_per_pass=10)
        print('Best value:', study.best_value)
        print('Best params:', study.best_params)

    # Setup method to initialize parameters and branches
    def setup(self):
        site_pkgs = os.path.expandvars('$HOME/.local/lib/python3.9/site-packages')
        if site_pkgs not in sys.path:
            sys.path.insert(0, site_pkgs)

        config = self.load_yaml('parameters.yaml')

        for name, p in config['parameters'].items():
            self.pars.append(Parameter(name, p))
            if p['branch'] not in self.branches:
                self.branches.append(p['branch'])
    
# Parameter class to hold parameter details
class Parameter():
    def __init__(self, name, p):
        self.name = name
        self.ptype = p['type']
        self.branch = p['branch']
        self.operator = p['operator']
        self.range = p['range']
        self.distribution = self.build_distribution()

    def build_distribution(self):
        if self.ptype == 'categorical':
            return CategoricalDistribution(self.range)
        elif self.ptype == 'float':
            return FloatDistribution(self.range[0], self.range[1])
        else:
            raise ValueError(f"Unsupported parameter type: {self.ptype}")


if __name__ == "__main__":

    files = ["/nashome/m/micarrig/icarus/NuE/nueOutputs/mcV4/mc.root:t_raw/t_raw"]
    branches = ['tNeutrinoType', 'rFiducial', 'rShowerDensity']
    
    mySearch = gridSearch(fileList=files, branches=branches)
    mySearch.setup()
    mySearch.run_batched_demo()