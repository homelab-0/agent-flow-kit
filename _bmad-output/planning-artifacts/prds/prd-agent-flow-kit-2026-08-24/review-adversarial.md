[
  {
    "location": "Open Questions",
    "trigger_condition": "The PRD says behavioral requirements and architecture reconciliation remain in discovery even though all four capabilities are frozen and the final architecture supplement declares coverage sufficient.",
    "guard_snippet": "Replace the stale sentence with a reconciled-decision record and list only genuinely unresolved implementation-planning questions, or state that no product questions remain open.",
    "potential_consequence": "Readers may reopen settled product discovery, treat frozen requirements as provisional, or block implementation planning unnecessarily."
  },
  {
    "location": "Architecture Constraints",
    "trigger_condition": "The authoritative responsibility matrix is only partially represented: the PRD does not explicitly state that Orca owns branch/worktree lifetime, process environment, secret isolation, concurrency, native session authentication, and coding-agent host selection, or that agent-flow-kit must not replace Orca's process/session manager.",
    "guard_snippet": "Add an explicit ownership constraint: Orca exclusively owns coding-session mechanics and agent-host selection; lifecycle may probe capabilities but may not create a competing session/process authority.",
    "potential_consequence": "An implementation or PR #5 mechanism could absorb Orca responsibilities while appearing consistent with the shorter boundary text."
  },
  {
    "location": "Architecture Constraints / Increment Boundary",
    "trigger_condition": "The final prox-ops boundary is not stated strongly enough: only a transitional validator note says a source checkout is not the long-term contract, while the authoritative supplement requires prox-ops to remain infrastructure and forbids a durable source-tree dependency.",
    "guard_snippet": "Add a hard constraint that prox-ops owns infrastructure deployment only and that lifecycle integration targets a compatible installed validator/client, never prox-ops repository layout or checkout availability.",
    "potential_consequence": "The accepted implementation may remain coupled to prox-ops source paths and turn an explicitly transitional bridge into the product interface."
  },
  {
    "location": "FR-17 through FR-21 and FR-47 through FR-53",
    "trigger_condition": "Two readiness models overlap: Capability 1 defines a single aggregate readiness and strongest-condition rule, while Capability 3 defines four independently blocked scopes. The PRD never defines aggregation precedence per scope or whether NEEDS_OWNER outranks NOT_READY.",
    "guard_snippet": "Define readiness as a vector keyed by scope, give deterministic precedence within each scope, and specify how overall_state is derived without collapsing HOST_EXECUTION, NEW_WORK, TARGET, and ROUTE readiness.",
    "potential_consequence": "Different implementations can emit contradictory verdicts for the same component results, breaking automation and operator trust."
  },
  {
    "location": "FR-17",
    "trigger_condition": "The statement that CURRENT execution-critical components yield READY is too broad and conflicts with FR-48, where Orca, validator, and a harness path are also required for host execution readiness.",
    "guard_snippet": "Change this to component-local integrity: CURRENT contributes a healthy component result but never independently establishes any aggregate readiness scope.",
    "potential_consequence": "A structurally current installation could be reported READY despite unavailable execution dependencies."
  },
  {
    "location": "FR-24, FR-27, FR-57, and FR-83 through FR-86",
    "trigger_condition": "Status and verify are described as reporting dependency/readiness and applicable router checks, but default operation is later defined as offline with external facts NOT_EVALUATED. The command contract does not say which results are mandatory offline versus live-only.",
    "guard_snippet": "Split each command's contract into offline integrity results and optional live readiness results; explicitly make network/auth-dependent checks NOT_EVALUATED unless live mode is requested.",
    "potential_consequence": "Implementations may make ordinary verify network-dependent or falsely mark unprobed external dependencies ready."
  },
  {
    "location": "FR-41",
    "trigger_condition": "The requirement says the lifecycle must record completed mutations before its first write, but completed-mutation state does not exist until writes occur.",
    "guard_snippet": "Require journal initialization before the first managed write, then durable journal updates after each mutation, with recovery metadata flushed before the corresponding destructive action.",
    "potential_consequence": "The impossible wording can yield a journal that is initialized correctly but never tracks progress, undermining interruption recovery."
  },
  {
    "location": "FR-37",
    "trigger_condition": "The exception for 'explicitly contracted unavoidable formatting behavior' is undefined and weakens the frozen byte-for-byte preservation ruling.",
    "guard_snippet": "Require byte-for-byte preservation by default and define any permitted normalization per component in machine-readable ownership metadata before adoption, with preflight evidence of the exact affected bytes.",
    "potential_consequence": "An updater can reformat or churn user-owned content while claiming the behavior was unavoidable."
  },
  {
    "location": "FR-54, FR-60, and FR-70",
    "trigger_condition": "Phrases such as 'deepest safe property available,' 'where available,' and 'prefer verified capabilities' do not establish a minimum conformance contract for Claude and Codex readiness.",
    "guard_snippet": "Define a required probe matrix per supported harness version/capability contract, including the exact minimum auth-mode, invocation, permission, and redirect/spend-safety evidence needed for READY versus WARNING versus NOT_READY.",
    "potential_consequence": "One adapter may report READY from a version check while another requires a native auth probe, defeating equivalent product behavior."
  },
  {
    "location": "FR-55 and Architecture Constraints",
    "trigger_condition": "Orca readiness lists required capabilities but does not explicitly prohibit lifecycle from managing worktrees, terminals, processes, concurrency, environment, or session state while satisfying those checks.",
    "guard_snippet": "State that Orca readiness is capability validation only and that all worker/session mutation occurs through Orca-owned interfaces during explicitly activated orchestration, never lifecycle status/adopt/update/verify.",
    "potential_consequence": "A lifecycle implementation could grow into a parallel worker launcher or session registry, violating the owner matrix."
  },
  {
    "location": "FR-63",
    "trigger_condition": "A requirement for future API-backed entitlements is outside this increment and describes prospective control-plane modeling rather than current lifecycle capability.",
    "guard_snippet": "Move the funding-shape warning to an architecture note: current detection must not infer funding solely from credential shape; future API-backed entitlement support is explicitly out of scope.",
    "potential_consequence": "Implementation planning may create new entitlement/funding features or duplicate router authority to satisfy a non-current requirement."
  },
  {
    "location": "FR-67",
    "trigger_condition": "Requiring the validator/client itself to expose machine-readable identity and semantics assigns a change to an external component, despite this increment explicitly not packaging the final client.",
    "guard_snippet": "Express the kit-side capability: it must obtain and validate compatible identity/contract evidence from the supported bridge or client; if the dependency cannot expose sufficient evidence, that path is incompatible and remains an external dependency gap.",
    "potential_consequence": "The increment could expand into prox-ops/client product development or be impossible to complete without authority over another product."
  },
  {
    "location": "FR-72 through FR-77",
    "trigger_condition": "The machine contract names stable codes and coarse exit classes but does not define the requested scope that controls exit status when multiple readiness scopes disagree.",
    "guard_snippet": "Add a required evaluated_scope/requested_scope field and normative exit mapping for status, verify, target-specific checks, route-specific checks, offline mode, and live mode.",
    "potential_consequence": "The same JSON result can legitimately produce different exit codes across implementations, making automation unreliable."
  },
  {
    "location": "FR-74 and FR-15 through FR-16",
    "trigger_condition": "Installation states, readiness verdicts, operation states, and availability states are placed into one loosely described state vocabulary, allowing semantically invalid combinations or an overloaded overall_state.",
    "guard_snippet": "Define separate typed enums for component integrity, ownership/drift, readiness verdict, source eligibility, operation outcome, and live availability, plus allowed mappings between them.",
    "potential_consequence": "Consumers may treat UNAVAILABLE as installation corruption, NEEDS_OWNER as readiness, or UPDATE_AVAILABLE as an operation result."
  },
  {
    "location": "FR-89",
    "trigger_condition": "The phrase 'worker counts where practical' is not testable and leaves the lifecycle bridge's required contract ambiguous.",
    "guard_snippet": "Either require counts only when present in the normalized source state and define exact pass-through fields, or remove worker counts from the requirement and leave them as a future enhancement.",
    "potential_consequence": "Acceptance cannot determine whether an omitted count is compliant, unavailable, or an implementation gap."
  },
  {
    "location": "AC-1 through AC-3",
    "trigger_condition": "Acceptance embeds volatile fleet names and selects the current PM host by preference, mixing product acceptance criteria with session-specific test planning despite the ruling to select hosts from observed fleet state.",
    "guard_snippet": "Replace named-machine exclusions and current-host preference with durable selection criteria; record chosen hosts and exclusions in the acceptance plan/evidence bundle after observed-state inspection.",
    "potential_consequence": "The PRD becomes stale when fleet names or availability change and can force a weaker host pair than observed evidence supports."
  },
  {
    "location": "AC-15 and AC-17",
    "trigger_condition": "A real PR and merge are mandatory acceptance mechanics, but the requirement does not define the authority, repository branch, review/CI gates, or what happens if the change is already merged before host testing.",
    "guard_snippet": "Define the product evidence as a canonical committed revision transition delivered through the normal protected Git workflow; put PR creation/merge authority and exact sequencing in the acceptance plan under repository governance.",
    "potential_consequence": "Acceptance can either bypass merge policy, become blocked by unrelated governance, or require an artificial extra PR solely to satisfy wording."
  },
  {
    "location": "AC-20 and AC-23",
    "trigger_condition": "The smoke must accept the natural valid route, while pre-launch evidence appears to require a native subscription route and no authorized metered fallback; the required behavior for a centrally valid but explicitly metered route is not stated.",
    "guard_snippet": "State that this acceptance smoke requests or requires a subscription-backed eligible route; if central policy returns an explicitly metered route, do not launch and classify the smoke blocked or reroute centrally without local substitution.",
    "potential_consequence": "The test may either violate the no-metered-spend intent or reject a valid router response without a defined reason."
  },
  {
    "location": "AC-21",
    "trigger_condition": "Retaining the complete immutable accepted stamp is required without explicitly constraining stamp fields to secret-free evidence, while Capability 4 prohibits secret output.",
    "guard_snippet": "Require a canonical secret-free stamp representation or retain only the signed payload fields, digest, expiry, and provenance necessary for proof; prohibit bearer credentials and sensitive headers in the evidence bundle.",
    "potential_consequence": "Acceptance evidence can become a credential or sensitive-policy exfiltration surface."
  },
  {
    "location": "AC-27",
    "trigger_condition": "Cleanup requires restoring the target repository 'exactly' while also retaining evidence, but does not define the baseline scope or permit unavoidable Orca/session metadata changes outside the repository.",
    "guard_snippet": "Define exact restoration as a captured repository/worktree baseline (branch, tracked tree, untracked set, and relevant lifecycle hashes) and separately enumerate permitted evidence/session artifacts outside that baseline.",
    "potential_consequence": "The cleanup gate is either impossible to prove or passes despite residue because 'exactly' is interpreted informally."
  },
  {
    "location": "AC-31",
    "trigger_condition": "The binary portability verdict requires live readiness to pass, so a transient router outage can block the product increment even when lifecycle portability is correct and outage semantics are explicitly separated from installation integrity.",
    "guard_snippet": "Define a bounded acceptance window and retry policy for external live probes, then distinguish PORTABILITY FAILED from ACCEPTANCE BLOCKED BY EXTERNAL AVAILABILITY while withholding GREEN until required live proof is eventually captured.",
    "potential_consequence": "A control-plane outage is misreported as a lifecycle defect, obscuring root cause and producing non-reproducible release decisions."
  },
  {
    "location": "NFR-1",
    "trigger_condition": "The requirement says all compatibility decisions are reproducible from declared state, but live reachability, authentication usability, and transient capability observations are time-dependent and intentionally not durable state.",
    "guard_snippet": "Require deterministic evaluation from declared contracts plus explicitly timestamped observations; identical inputs and observations must yield identical results, while live observations may legitimately change over time.",
    "potential_consequence": "The NFR is unattainable as written or encourages persistence of transient external state into the installation manifest."
  },
  {
    "location": "FR-88 and AC-18 through AC-27",
    "trigger_condition": "The orchestration regression and smoke requirements heavily repeat existing EPIC-035 behavior but never identify the precise existing visibility/dispatch contract version that must remain compatible.",
    "guard_snippet": "Reference a versioned existing orchestration/session-state contract and frame acceptance as compatibility regression against it, with only lifecycle-specific bridge additions treated as new behavior.",
    "potential_consequence": "Implementers may rebuild proven orchestration features, or acceptance may pass against an ad hoc interpretation that misses a real regression."
  }
]
