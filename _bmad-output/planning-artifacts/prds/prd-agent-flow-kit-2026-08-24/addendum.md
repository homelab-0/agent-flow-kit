# Agent Flow Kit Portability and Maintenance — Addendum

This addendum preserves implementation and comparison material that informs downstream architecture without prescribing the PRD's product contract.

## Candidate Lifecycle Mechanisms

- A secret-free operation journal could carry an operation ID, previous and target revisions, planned components, pre-mutation hashes or state, backup locations, and completed mutation markers.
- Applied-state metadata could use a platform-appropriate atomic replacement sequence such as writing a temporary file, flushing it, and renaming it only after full verification.
- Managed shared-file content may use deterministic section markers, but the exact section representation and merge mechanism remain architecture decisions.
- First-increment interruption recovery should prefer rollback over resumable transactions.

## Comparable Product Patterns

Primary-source research into established configuration lifecycle tools supports several product patterns relevant to architecture: narrow explicit ownership, complete conflict preflight before mutation, explicit adoption of unknown state, separate canonical/desired/local/actual layers, declared machine differences, read-only status/diff/doctor surfaces, drift interlocks, convergent no-op updates, recoverable generations, and distinct machine-readable versus human diagnostics. These patterns are evidence, not implementation requirements.

- GNU Stow ownership and deferred conflict operations: https://www.gnu.org/software/stow/manual/stow.html
- chezmoi concepts and lifecycle commands: https://www.chezmoi.io/reference/concepts/ and https://www.chezmoi.io/user-guide/command-overview/
- Nix profile generations and rollback: https://releases.nixos.org/nix/nix-2.32.3/manual/package-management/profiles.html
