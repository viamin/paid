# frozen_string_literal: true

module Prompts
  # Builds a prompt for an agent to perform LID brownfield analysis and
  # produce a docs-only Planning PR: seeded HLD, LLDs with [inferred]/authored
  # markers, EARS specs, arrows index, and a ## LID block in the instruction
  # file.
  #
  # The prompt encodes the brownfield procedure from docs/lid/workflow.md
  # § Brownfield LLD content plus the five audit checks.  The service is
  # goal-agnostic beyond its own slug — it expects `lid_planning` to be the
  # run goal but does not gate on it, so callers own routing.
  #
  # @example
  #   prompt = Prompts::BuildForLidPlanning.call(project: project)
  #   prompt = Prompts::BuildForLidPlanning.call(project: project, plan_doc_source: "docs/rdrs/RDR-051.md")
  class BuildForLidPlanning
    PROMPT_SLUG = "lid.planning"

    # Section prepended to the rendered prompt when the user names an existing
    # plan document for the conversion path. Tells the agent to treat that doc's
    # decisions as authored intent rather than [inferred].
    def self.plan_doc_section(plan_doc_source)
      <<~SECTION
        ## User-specified plan document

        The project owner has identified the following as authored intent. Read it
        fully before drafting any LLD: decisions sourced from it carry authored
        rationale (no `[inferred]` marker), and its stated scope is binding.

        #{plan_doc_source}
      SECTION
    end

    # Fallback used only if the seeded prompt is missing or deactivated.
    # The active template lives in db/seeds/prompts.rb under PROMPT_SLUG.
    FALLBACK_PROMPT = <<~'PROMPT'
      # Task

      You are performing Linked-Intent Development (LID) brownfield analysis on the
      repository at hand. Your goal is to produce a **docs-only** Planning Pull Request
      that bootstraps the LID design tree so the project owner can review, correct, and
      adopt it.

      ## Procedure

      Follow the LID brownfield procedure as defined in `docs/lid/workflow.md` § Brownfield
      LLD content, plus the five audit checks from `docs/lid/audit-checklist.md`.

      ### 1. Read the repository

      - Read the codebase: significant source files, `db/schema.rb` or equivalent,
        configuration, and any existing architecture documentation.
      - Read any named plan documents the user has identified (RDRs, ADRs, design docs,
        READMEs). These carry **authored intent** — decisions sourced from them carry
        authored rationale, not `[inferred]`.

      ### 2. Produce docs-only changes (NO code changes)

      Produce the following artifacts under `docs/`.  Do NOT modify any code, tests, or
      configuration outside of `docs/` and the instruction file.

      #### a. `docs/high-level-design.md`

      Seed or update a top-level HLD.  Use the standard template from
      `docs/lid/hld-template.md`.  Include:

      - `## Problem` — what problem the project solves, derived from the README, plan
        docs, and observed structure.
      - `## Approach` / `## System Design` — the architectural approach.
      - `## Tenets` — 2-5 load-bearing design principles that a fresh author would
        independently write (apply the defensible-opposite test; drop platitudes).

      #### b. `docs/intent/<segment>/` LLDs

      Create one leaf LLD per major component / subsystem.  Use the standard template
      from `docs/lid/lld-templates.md`.  Each LLD includes:

      - **Context & Scope** — what this component owns and its boundaries.
      - **Decisions & Alternatives** table.  For each decision:
        - If observed in code without a plan-doc source, mark the Rationale column
          `[inferred]` and record the observed behavior.
        - If sourced from a plan doc, record the authored rationale (no `[inferred]`).
      - **Open Questions & Future Decisions** — observed-but-unexplained behaviors and
        technical debt found during reconnaissance.

      #### c. EARS specs

      For each LLD, create companion EARS specs at `docs/intent/<segment>/<segment>-specs.md`
      using the format from `docs/lid/ears-syntax.md`.  Use path-concatenated spec IDs
      (e.g. `AUTH-001`).  Mark each spec:

      - `[x]` — observed in existing code / tests.
      - `[ ]` — described in docs but not observed in code.
      - `[D]` — deferred (not yet implemented or out of current scope).

      After drafting, run the post-draft consistency checks:
      - Coverage: are there LLD behaviors with no spec?
      - Contradiction: do any specs conflict?
      - Implicit scoping: are any specs universal when they apply only to one context?

      #### d. `docs/arrows/index.yaml`

      Create an arrow overlay index documenting the design tree structure.  Each entry
      records the segment path, status, and parent/child relationships.

      #### e. Instruction file (`AGENTS.md`)

      - If the project already has an `AGENTS.md` (or `CLAUDE.md`), add a `## LID` block
        at the end:
        ```
        ## LID

        - Mode: Full
        - Version: 1.3.0
        ```
      - If neither file exists, create `AGENTS.md` with the `## LID` block plus a note
        that it was bootstrapped by Paid.
      - Do NOT change any *other* content in the instruction file.

      ### 3. Open a docs-only Planning PR

      - Branch name: `lid/planning-bootstrap`
      - Commit message: `docs: bootstrap LID design tree`
      - PR title: `docs: bootstrap LID design tree`
      - PR description: include a "Confirm these inferred decisions" checklist listing
        every load-bearing `[inferred]` decision and any gaps surfaced by the edge audit.
        Format each item as a Markdown checkbox with the segment and decision text.

      The PR MUST contain ONLY `docs/` files and the instruction-file change.  No code.

      ### 4. Edge audit (Phase 4)

      After drafting all specs, run the intent-narrowing edge audit from
      `docs/lid/workflow.md` § Phase 4:

      - Cross-segment interactions: who owns what state?
      - Specs that admit two interpretations when composed.
      - Namespace / mode ambiguity.
      - Sequencing ambiguity.
      - Places where the user's latent intent is narrower than what the specs allow.

      Surface any genuine gaps in the PR description checklist.

      ### 5. Coherence verification

      Run `bin/coherence-check.mjs` if available and surface structural findings in the
      PR description.  If the checker is not available, perform the structural checks
      in-prompt:
      - Every `@spec` annotation points to an existing spec ID.
      - Every behavioral EARS spec cited by an LLD has at least one citing test.
      - No spec file references a deleted spec ID.

      ## Rules

      - **Docs only.**  Do not create, modify, or delete any source code, tests, or
        configuration outside of `docs/` and the instruction file.
      - **Same template, same sections.**  Brownfield LLDs use the same template as
        greenfield ones — what varies is the content's starting state.
      - **[inferred] decisions.**  Every decision reverse-engineered from code carries
        `[inferred]` in the Rationale column.  Do not guess intent — record what the
        code does and mark it.
      - **Authored decisions.**  Every decision sourced from a named plan doc carries
        the doc's rationale verbatim (or summarized, with source citation).
      - **Context-free docs.**  Every HLD, LLD, and spec must read as if authored fresh
        today, by someone who knew only the current intent and nothing of this
        conversation.  No narration of how intent changed; no conversational residue.
      - **Use the vendored templates.**  Reference `docs/lid/hld-template.md`,
        `docs/lid/lld-templates.md`, `docs/lid/ears-syntax.md`, and
        `docs/lid/audit-checklist.md` for structure and format.

      When you're done, commit your changes and open the PR.  Do not push to main.
    PROMPT

    attr_reader :project, :plan_doc_source

    def initialize(project:, plan_doc_source: nil)
      @project = project
      @plan_doc_source = plan_doc_source.to_s.strip
    end

    def self.call(...)
      new(...).build
    end

    def build
      vars = {
        project_name: project.name,
        full_name: project.full_name
      }

      base = Prompts::Render.call(
        slug: PROMPT_SLUG,
        project: project,
        variables: vars,
        fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
      )

      plan_doc_source.present? ? inject_plan_doc(base) : base
    end

    private

    def inject_plan_doc(base)
      "#{self.class.plan_doc_section(plan_doc_source)}\n#{base}"
    end
  end
end
