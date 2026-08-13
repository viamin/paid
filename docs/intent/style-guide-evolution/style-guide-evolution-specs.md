# EARS Specs: Style Guide Evolution

> Testable claims for the style-guide versioning, exposure-tracking,
> evolution, and A/B-testing pipeline (RDR-035). Status markers:
> `[x]` implemented · `[ ]` active gap · `[D]` deferred.
> Each ID is a grep target across specs, tests, and code
> (`grep -r STYLE-GUIDE-EVOLUTION-001`).

## Versioning

- [x] **STYLE-GUIDE-EVOLUTION-001** — When a `StyleGuideVersion` is updated
  after creation, the system SHALL reject changes to its content-identity
  attributes (`raw_content`, `version`, `style_guide_id`,
  `created_by_user_id`, `parent_version_id`, `created_by`, `change_notes`) so
  persisted version content is immutable.
- [x] **STYLE-GUIDE-EVOLUTION-002** — When a `StyleGuideVersion` declares a
  `parent_version`, the system SHALL reject the record unless the parent
  belongs to the same `style_guide`, keeping lineage scoped to one guide.

## Exposure Tracking and A/B Assignment

- [x] **STYLE-GUIDE-EVOLUTION-003** — When `StyleGuides::InjectIntoPrompt` is
  called with an `agent_run`, the system SHALL record one
  `StyleGuideRunExposure` per injected guide capturing the resolved
  `style_guide_version`, `source_scope`, `position`, and `injected_via`
  source.
- [x] **STYLE-GUIDE-EVOLUTION-004** — When a running `StyleGuideAbTest` exists
  for a guide's account and the run has no existing assignment, the system
  SHALL enroll the run in the test through `StyleGuideAbTests::Assign` and
  inject the assigned variant's version content instead of the guide's
  current version.
- [x] **STYLE-GUIDE-EVOLUTION-005** — When `StyleGuideAbTests::Assign` selects
  a variant for a run, the system SHALL weight selection toward variants with
  fewer existing assignments and SHALL return the same assignment on repeat
  calls for the same `(style_guide_ab_test, agent_run)` pair.

## Evolution Candidate Sampling

- [x] **STYLE-GUIDE-EVOLUTION-006** — When `StyleGuideEvolution::SampleRuns`
  evaluates a style guide version, the system SHALL flag it as an evolution
  candidate only when it has at least `MIN_RUNS_FOR_EVALUATION` sampled runs
  in the trailing window and its average composite quality score is below
  `QUALITY_THRESHOLD`.

## Mutation Generation

- [x] **STYLE-GUIDE-EVOLUTION-007** — When `StyleGuideEvolution::Mutate`
  generates variants, the system SHALL redact the current guide content
  before sending it to the LLM, SHALL request a bounded mutation count, and
  SHALL discard any generated variant whose content exceeds
  `MAX_GENERATED_TEMPLATE_LENGTH`.

## Variant Persistence and Orchestration

- [x] **STYLE-GUIDE-EVOLUTION-008** — When `StyleGuideEvolution::CreateVariants`
  persists a mutation, the system SHALL create a new `StyleGuideVersion` whose
  `parent_version` is the style guide's current version, and SHALL reuse an
  existing version instead of creating a duplicate when the same idempotency
  key, content, and strategy were already persisted.
- [x] **STYLE-GUIDE-EVOLUTION-009** — When `StyleGuideEvolutionJob` runs, the
  system SHALL select only active, non-global style guides that have a
  current version, have received exposures within the sample window, and are
  not already enrolled in a running A/B test for their account, and SHALL
  start one `Workflows::StyleGuideEvolutionWorkflow` per eligible guide.
- [x] **STYLE-GUIDE-EVOLUTION-010** — When `Workflows::StyleGuideEvolutionWorkflow`
  executes, the system SHALL run sampling, mutation generation, variant
  creation, and A/B test creation as a sequential activity chain, and SHALL
  stop and return a status of `no_candidates`, `no_mutations`, or
  `no_variants_created` if an earlier stage produces no output.

## Quality Attribution, Analysis, and Promotion

- [x] **STYLE-GUIDE-EVOLUTION-011** — When `StyleGuideAbTests::RecordResult`
  records a quality score for a run's assignment, the system SHALL update the
  assigned variant's `sample_count`, `total_quality_score`, and
  `avg_quality_score`, and SHALL NOT overwrite an existing recorded score
  unless `update_existing` is explicitly set.
- [x] **STYLE-GUIDE-EVOLUTION-012** — When a running `StyleGuideAbTest`
  reaches sufficient samples per variant, the system SHALL analyze the test
  via `StyleGuideAbTests::Analyze` and SHALL complete the test, promoting the
  winning variant when the analysis finds a statistically significant winner,
  or completing without promotion when control wins or the difference is not
  significant.
- [x] **STYLE-GUIDE-EVOLUTION-013** — When `StyleGuideAbTests::Analyze`
  compares a variant to the control arm, the system SHALL use a Welch's
  t-test against the configured `confidence_threshold` and SHALL require at
  least two scored samples per arm before returning a conclusive result.
- [x] **STYLE-GUIDE-EVOLUTION-014** — When `StyleGuideAbTests::PromoteWinner`
  promotes a winning version, the system SHALL copy the winning version's raw
  content onto the mutable `style_guides` row, set it as the
  `current_version_id`, clear cached compression, and enqueue recompression.
