# Changelog

## 0.2.1 — initial public release

- Publish Windows/WPF HUD with optional WSL Docker probes.
- Bound Windows rollout-tail reads to avoid large-log stalls.
- Drain app-server stderr to avoid initialization deadlock.
- Correct WSL direct-exec arguments and PowerShell reserved-variable collision.
- Mark cached quota explicitly and report quota failures.
- Add generic configuration, bilingual documentation, synthetic demo and offline checks.
