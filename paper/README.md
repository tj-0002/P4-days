# The paper

**P4-Days: Programmable Data-Plane Execution in a Multicore Discrete-Event
Network Simulator** — [`P4-Days.pdf`](P4-Days.pdf)

A preprint, not yet peer reviewed.

**Cite it as [`10.5281/zenodo.22899521`](https://doi.org/10.5281/zenodo.22899521)**
— that is the concept DOI and always resolves to the newest version. This
version is archived separately as `10.5281/zenodo.22899522`; use the concept
DOI unless you need to pin this exact text.

`CITATION.cff` in the repository root carries the same thing in
machine-readable form, which is what GitHub's "Cite this repository" button
reads.

## Every number in it is reproducible from this repository

| paper | where it comes from |
|---|---|
| Table I, agreement in 11 of 16 scenarios | `days/artifact/results/*/registers.csv` — diff the `days` and `ns3` rows |
| Table II, multicore scaling | `experiments/multicore/results/scaling.csv` |
| Table III, memory | the `peak_rss_mb` column of the same file |
| single-worker runtime ratios | `days/artifact/results/summary.csv` |
| per-hop cost decomposition | `P4D_PROFILE=1`, see [`docs/usage.md`](../docs/usage.md) |

The register evidence is committed in collapsed form — non-zero rows only,
0.1 MB rather than 123 MB — so the central agreement result can be re-derived
without running either simulator. [`docs/experiments.md`](../docs/experiments.md)
is the full write-up, including where the two simulators disagree and why
neither is wrong.

## Licence

The manuscript and its figures are **copyright the author, all rights
reserved**. The AGPL-3.0 that covers the rest of this repository applies to the
software, not to the paper.
