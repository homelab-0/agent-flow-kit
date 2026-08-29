# AFK-PORT-1.4-M2D-UPDATE-RERUN classification

## Persona gate

- Required outer SHA-256: `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`.
- Observed outer SHA-256: `07ee71cffbefa3372dda5a882a82acdd526fac49a468322088607061c404a4ee`.
- Result: matched.

## Lane 1 — update delivery precondition

- Canonical checkout revision: `fbc0923a2513beee5527afde57cd69c5600a735a`.
- Installed applied revision: `8a7cbc194fd56114d65c7dfd6a42106c807fb46b`.
- Required result: `UPDATE_AVAILABLE`.
- Observed installed state: `CURRENT`.
- Observed managed component states: all `CURRENT` (with the expected machine-local/user-owned adaptations).
- Source eligibility revision relation: `AHEAD`.
- Status exit: `0`; overall state: `READY_WITH_WARNINGS`.
- Ambiguity: the applied revision is behind the canonical checkout, but the lifecycle status does not classify the installation or any component as `UPDATE_AVAILABLE`.

The brief makes `UPDATE_AVAILABLE` a mandatory gate and requires stopping on any error, refusal, or ambiguity. Therefore `update --plan`, approval, update execution, preservation comparison, post-update verification, and the live-verification rerun were not executed; no lifecycle mutation occurred.

LIVE: NOT_RUN — REASONS-GROUNDED: no — AMBIGUITY: status reports CURRENT despite applied revision behind canonical checkout

Overall outcome: `failed` at the Lane 1 hard gate.
