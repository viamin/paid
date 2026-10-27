# Operational Supervisor Arrow

## References

- HLD: `docs/high-level-design.md`
- Decision: `docs/rdrs/RDR-063-operational-supervisor-delivery-health.md`
- LLD: `docs/intent/operational-supervisor/operational-supervisor-design.md`
- EARS: `docs/intent/operational-supervisor/operational-supervisor-specs.md`
- Delivery work: #4708, #4709, #4710, #4711, #4712, #4713, #4714

## Spec coverage

All `OPERATIONAL-SUPERVISOR-*` claims are planned. Implementation tasks must
add failing-first tests and `@spec` anchors before runtime code. The initial
slice is off-by-default shadow observation only; #4713 is separately held for
any mitigation authorization.

## Key findings

Notifications/Inbox, `AgentRunAnomaly`, dispatch circuit breakers, auto-pick
gates, guardrails, and PR escalation recovery are reuse candidates, not a
substitute for an account-level sanitized observer. No implementation existed
at this audit.
