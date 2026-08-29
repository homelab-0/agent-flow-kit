# Incident resolution — lost worker_done (discovery worker, 2026-08-27)

Timeline:
1. Worker's original worker_done send visibly ran but never committed — it used
   an out-of-grammar flag (--report-path) and did not verify the exit status.
   The Run mailbox held only heartbeats; the dispatch stayed `dispatched`.
2. Coordinator retained the transcript + mailbox-peek + dispatch-show evidence
   (files beside this one), then directed a resend FROM THE WORKER'S OWN
   TERMINAL via dispatch mail + a terminal wake (idle TUI workers do not
   consume inbox mail on their own). No completion was fabricated.
3. First resend was REJECTED by Orca: "The Dispatch capability is missing" —
   the worker had dropped its injected --dispatch-capability token. This is the
   enforcement side of the durable-completion contract: Orca refuses a
   worker_done that cannot prove its dispatch authority; worker prose alone
   settles nothing. (Delivery delivery_659267244190, msg_0fdbac2cc594.)
4. Corrected resend (original command minus only --report-path, capability
   kept) was ACCEPTED: msg_7eb406b9d254, delivery_917b9996639f. The dispatch
   auto-settled `completed` at 2026-08-27 07:30:43; worker released; tab
   closure verified via terminal list.

Acceptance relevance: a naturally occurring committed-looking-but-uncommitted
completion plus a capability-gate rejection, both recovered without duplicate
settlement — live supporting evidence for the registered turn-boundary /
durable-delivery condition. The M4 smoke must still prove `monitor --reconcile`
consuming a real delivery across a coordinator turn boundary on the kit's own
watch machinery.
