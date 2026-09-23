# EARS Specs: Facet Confidence

Status: `[ ]` planned; no implementation is claimed by these specs.

- [ ] **FACET-CONFIDENCE-001** — When assessing a feature or issue facet, Paid SHALL represent intent certainty and technical confidence separately on a 0–100 scale and SHALL represent unknown values explicitly rather than inventing human intent.
- [ ] **FACET-CONFIDENCE-002** — When an agent produces a facet assessment, Paid SHALL record its evidence references, evidence revision, rubric/model version and concise explanation through the agent_harness interface.
- [ ] **FACET-CONFIDENCE-003** — When human statements contradict earlier directions, Paid SHALL preserve attribution, honor explicit corrections over superseded evidence, and ask for clarification of unresolved disagreement rather than count statements as votes.
- [ ] **FACET-CONFIDENCE-004** — When assessing intent certainty, Paid SHALL NOT treat repeated agent suggestions, duplicated evidence or incidental UI interactions as additional human agreement.
- [ ] **FACET-CONFIDENCE-005** — When a user challenges an assessment in chat, Paid SHALL retain the challenge as evidence and reassess the affected facets with a visible explanation.
- [ ] **FACET-CONFIDENCE-006** — When uncertainty admits distinguishing questions, Paid SHALL ask context-appropriate comparative questions and allow conditional, both/neither and free-text answers.
- [ ] **FACET-CONFIDENCE-007** — When persisting a durable preference, Paid SHALL require an explicit user statement and an explicit or clarified scope, retain its provenance, and permit authorized inspection, correction and deletion; it SHALL NOT infer durable preferences from behavior.
- [ ] **FACET-CONFIDENCE-008** — When an issue's material prerequisites are mapped, Paid SHALL retain the agent's mapping rationale and coverage assessment, including relevant design documents, and SHALL NOT consider an unassessed empty mapping ready.
- [ ] **FACET-CONFIDENCE-009** — When evaluating initial issue readiness, Paid SHALL require each material facet's known intent and technical scores to meet their respective project thresholds without averaging across facets or requiring unrelated feature facets to pass.
- [ ] **FACET-CONFIDENCE-010** — When confidence settings are initialized, Paid SHALL default intent and technical thresholds to 80/100 each and SHALL permit independently authorized, audited project configuration within 0–100.
- [ ] **FACET-CONFIDENCE-011** — When assessing a research issue, Paid SHALL assess clarity and feasibility of its investigation scope rather than require certainty about the implementation answer the investigation seeks.
- [ ] **FACET-CONFIDENCE-012** — When an assessment is invalid, fails, or targets superseded evidence, Paid SHALL NOT apply it as a current passing assessment and SHALL expose the unresolved assessment state.
- [ ] **FACET-CONFIDENCE-013** — When presenting assessments or constructing builder context, Paid SHALL include both scores and relevant evidence summaries and SHALL distinguish expressed intent, inferred fit and demonstrated feasibility.
- [ ] **FACET-CONFIDENCE-014** — While displaying Inbox or chat state, Paid SHALL read persisted assessments without making per-entry synchronous LLM calls.
- [ ] **FACET-CONFIDENCE-015** — For confidence-driven features, when project thresholds or facet evidence change after a run starts, Paid SHALL route resulting findings through the confidence-driven delivery policy without using this change alone to pause that run.
