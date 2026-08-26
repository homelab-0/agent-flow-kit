[
  {
    "location": "prd.md:71-74",
    "trigger_condition": "Approved plan becomes stale before its mutations begin",
    "guard_snippet": "recompute_and_match(plan_digest, observed_state) || refuse(PLAN_STALE)",
    "potential_consequence": "Previously approved authority overwrites content changed after planning"
  },
  {
    "location": "prd.md:97-103",
    "trigger_condition": "Two lifecycle mutations execute concurrently on one installation",
    "guard_snippet": "acquire_exclusive_installation_lock() || refuse(OPERATION_IN_PROGRESS)",
    "potential_consequence": "Interleaved journals and writes corrupt state or revision metadata"
  },
  {
    "location": "prd.md:80-86",
    "trigger_condition": "Checkout inputs change after eligibility check but before copying",
    "guard_snippet": "pin_source_tree(commit, input_hashes); revalidate_before_each_read()",
    "potential_consequence": "Uncommitted or unintended content enters installed canonical state"
  },
  {
    "location": "prd.md:90-102",
    "trigger_condition": "Managed destination changes after preflight but before replacement",
    "guard_snippet": "compare_current_to_preflight_hash() || abort_and_preserve_external_change()",
    "potential_consequence": "Concurrent user edits are silently overwritten during update"
  },
  {
    "location": "prd.md:35-46",
    "trigger_condition": "Managed destination is a symlink or escapes its declared root",
    "guard_snippet": "resolve_without_following_links(path); require_within_owned_root_and_expected_type()",
    "potential_consequence": "Lifecycle reads or overwrites user-owned paths outside its authority"
  },
  {
    "location": "prd.md:45,92",
    "trigger_condition": "Registered adaptation no longer matches its expected local shape",
    "guard_snippet": "adaptation_matches_record() || state(LOCAL_DRIFT, NEEDS_OWNER)",
    "potential_consequence": "Stale exception legitimizes new unexplained managed-content drift"
  },
  {
    "location": "prd.md:45,74,92",
    "trigger_condition": "Source update invalidates a preserve-only registered adaptation",
    "guard_snippet": "evaluate_adaptation_disposition(target_revision) || require_owner_review()",
    "potential_consequence": "Host reports ready despite adaptation violating the new contract"
  },
  {
    "location": "prd.md:58-64",
    "trigger_condition": "BROKEN and NEEDS_OWNER conditions coexist across components",
    "guard_snippet": "define_total_precedence(NOT_READY, NEEDS_OWNER, READY_WITH_ADAPTATION, READY_WITH_WARNINGS, READY)",
    "potential_consequence": "Different implementations emit contradictory overall readiness states"
  },
  {
    "location": "prd.md:109-115,166-170",
    "trigger_condition": "Offline evaluation leaves all harness usability facts not evaluated",
    "guard_snippet": "host_execution=NOT_EVALUATED unless one complete harness path is positively proven",
    "potential_consequence": "Offline status can falsely claim host execution readiness"
  },
  {
    "location": "prd.md:112,210-218",
    "trigger_condition": "Accepted route requires late-bound local inference placement",
    "guard_snippet": "if stamp.requires_placement: place_immediately_before_dispatch_and_validate_result()",
    "potential_consequence": "Smoke bypasses router placement authority or cannot launch valid route"
  },
  {
    "location": "prd.md:111-115,210-218",
    "trigger_condition": "Accepted stamp expires between final validation and worker launch",
    "guard_snippet": "require_stamp_valid_at_launch(); otherwise reroute_or_refuse()",
    "potential_consequence": "Worker launches using an execution decision no longer authorized"
  },
  {
    "location": "prd.md:99-102,198,223",
    "trigger_condition": "Rollback restores bytes but not ownership permissions or metadata",
    "guard_snippet": "snapshot_and_restore(mode, owner, group, acl, xattrs, link_type)",
    "potential_consequence": "Recovered files remain unusable or expose broader access"
  },
  {
    "location": "prd.md:175-176",
    "trigger_condition": "Normalized orchestration state exists but uses unsupported schema",
    "guard_snippet": "if unsupported_session_schema: report orchestration UNKNOWN with incompatibility reason",
    "potential_consequence": "Lifecycle misreports active mode or silently drops NEEDS HUMAN"
  },
  {
    "location": "prd.md:204-206,223-226",
    "trigger_condition": "Primary host has no safely testable meaningful legacy installation",
    "guard_snippet": "select_stalest_qualifying_host_or_block_with_no_representative_host_evidence()",
    "potential_consequence": "Acceptance substitutes manufactured state without recording a blocked criterion"
  }
]
