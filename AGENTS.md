# Repository Instructions

## Quench namespace and release rules

- Quench owns and maintains every module in this repository, including `src/modules/bbr.sh`.
- Quench-owned runtime paths, services, locks, configuration markers, temporary files and environment variables must use the `quench` / `QUENCH_*` namespace.
- Keep the version in source, generated script, documentation, manifest, tags and release assets synchronized.
- After changing source modules, rebuild `vps-quench.sh` and run the relevant syntax, smoke, fault-injection and offline-package checks.
- Do not place GitHub tokens in the repository or command history.
