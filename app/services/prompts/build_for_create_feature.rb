# frozen_string_literal: true

module Prompts
  # @spec CREATE-FEATURE-001
  # @spec CREATE-FEATURE-002
  # @spec CREATE-FEATURE-003
  # @spec RDR-ROLLOUT-GUARD-003
  #
  # Builds the agent prompt for a `create_feature` run. The run is responsible
  # for taking a structured feature brief (collected via chat or the
  # needs-input/clarifying-questions flow), researching the repo, writing an
  # RDR document, updating `docs/rdrs/README.md`, opening a docs-only PR, and
  # decomposing the RDR's Implementation Plan into a tree of linked GitHub
  # issues.
  #
  # The brief is sourced from `agent_run.external_metadata["feature_brief"]`
  # (see RDR-053 §2). The repo is the source of truth for RDR numbering — the
  # agent reads the highest existing `docs/rdrs/RDR-*.md` number and increments.
  # A `target_rdr_number` in the brief, when present, pins the numbering.
  #
  # The composed prompt is sourced from the DB-stored prompt
  # (`coding.create_feature_prompt`) when present, falling back to the
  # in-code `FALLBACK_PROMPT` so the run can execute before seed completion.
  # This mirrors RDR-009's prompt-evolution pattern.
  class BuildForCreateFeature
    PROMPT_SLUG = "coding.create_feature_prompt"

    # Documentation copy of the prompt this class builds. Seeded into the
    # Prompts admin UI for reference; `build` composes the live prompt from
    # project_name/feature_brief/lid_mode and does not render this template.
    FALLBACK_PROMPT = <<~'PROMPT'.freeze
      # Task

      Create a new feature for {{project_name}} ({{full_name}}) by authoring an RDR
      (Recommendation Decision Record) and a tree of implementation issues.

      # Feature brief

      The user has provided the following structured brief for this feature.
      Use it as the seed for the RDR's Problem Statement, Context, and
      Proposed Solution; do not invent facts the brief does not support.

      {{feature_brief}}

      {{lid_section}}

      # Instructions

      1. **Research**: Read the repository. Identify the files, modules, and
         conventions relevant to the brief. Read the existing RDRs under
         `docs/rdrs/` for format and tone, plus `docs/rdrs/README.md` for the
         index layout and section structure. Read `docs/ARCHITECTURE.md`,
         `docs/STYLE_GUIDE.md`, and any other relevant architecture doc.
      2. **Number the RDR**: List `docs/rdrs/RDR-*.md`, find the highest
         existing number, and add one. If the feature brief specifies a
         `target_rdr_number`, use that instead.
      3. **Write the RDR**: Create `docs/rdrs/RDR-0XX-<slug>.md` (slug is a
         short kebab-case summary of the title) following the section
         structure in `docs/rdrs/README.md`:
         - Metadata (date, status: Draft, type, priority, related RDRs/issues)
         - Problem Statement
         - Context
         - Research Findings
         - Proposed Solution (with rationale)
         - Alternatives Considered
         - Trade-offs and Consequences
         - Rollout Guard
         - Implementation Plan (phases/steps)
         - Validation (testing approach and scenarios)
      4. **Update the index**: Add a row for the new RDR to `docs/rdrs/README.md`
         in the appropriate section, matching the table format already in use.
      5. **Open a docs-only PR**: Open a pull request whose diff contains only
         the new RDR file and the README update. Describe the PR so a reviewer
         can find the feature brief for context. Do not include code changes.
      6. **Decompose into an issue tree**: Read the RDR's Implementation Plan
         and produce one epic issue plus one issue per phase (or per task, for
         small RDRs). Each issue body must:
         - Reference the RDR by number (`Part of RDR-0XX`)
         - Link to its parent and child issues via body text using the
           existing convention (`Depends on #N` or `Blocked by #N` inline, or
           a `## Dependencies` section for multiple links)
         Be parseable by `Issues::ParseDependencies`. File issues via the
         existing cross-repo issue-filing path.

      # Rules — you MUST follow these

      - **Research before writing.** Every claim in the RDR's Context and
        Research Findings sections must trace to a real file, symbol, or doc.
        Do not invent components that do not exist.
      - **Honour the brief.** Do not invent facts the brief does not support.
        If the brief is silent on something the RDR requires, mark it as
        `[inferred]` and surface it in the PR description for human review.
      - **RDR numbering is repo-derived.** Do not hardcode numbers; the repo
        is the source of truth.
      - **Docs-only PR.** The RDR PR must contain only `docs/rdrs/` changes.
        No code, no test, no config edits in the same PR.
      - **Issues reference the RDR.** Every filed issue must link back to the
        RDR by number so the tree is traceable to the specification.
      - **Guard incomplete runtime behavior.** If the RDR changes runtime
        behavior, its `## Rollout Guard` section must name a feature flag or
        config gate, default state, enablement surface, rollback action, and
        cleanup criteria. For feature flags, name the implementation issue that
        adds the key to `FeatureFlags::DEFINITIONS` and wires the runtime
        decision through `FeatureFlags.enabled?(:flag_name, project:)`. Use
        `docs-only`, `migration-only`, or `none required` only with a short
        justification. Implementation issues must preserve that guard until the
        RDR closeout audit marks the behavior complete and safe by default.
      - **Lint and tests MUST pass** for any non-RDR changes (none expected in
        this run).

      When you're done, commit and push the RDR PR. Do not merge.
    PROMPT

    def self.call(...)
      new(...).build
    end

    attr_reader :project_name, :full_name, :feature_brief, :lid_mode

    def initialize(project_name:, full_name:, feature_brief:, lid_mode: nil)
      @project_name = project_name
      @full_name = full_name
      @feature_brief = feature_brief.to_h
      @lid_mode = lid_mode
    end

    def build
      Prompts::Render.call(
        slug: PROMPT_SLUG,
        project: nil,
        variables: variables,
        fallback: -> { fallback_prompt }
      )
    end

    private

    def variables
      {
        project_name: project_name,
        full_name: full_name,
        feature_brief: formatted_brief,
        lid_mode: lid_mode.to_s,
        lid_section: lid_section
      }
    end

    def formatted_brief
      [
        "Title: #{feature_brief['title']}",
        "",
        "Problem: #{feature_brief['problem']}",
        "",
        "Desired behavior: #{feature_brief['desired_behavior']}",
        "",
        brief_section("Constraints", feature_brief["constraints"]),
        brief_section("Rejected alternatives", feature_brief["rejected_alternatives"]),
        scope_section,
        "",
        "Done criteria: #{feature_brief['done_criteria']}",
        "",
        "LID requested: #{feature_brief['lid_requested']}",
        "Target RDR number: #{feature_brief['target_rdr_number'] || '(derive from repo)'}"
      ].compact.reject(&:empty?).join("\n")
    end

    def brief_section(label, items)
      return nil if Array(items).blank?

      "#{label}:\n" + Array(items).map { |item| "- #{item}" }.join("\n")
    end

    def scope_section
      scope = feature_brief["scope"]
      return nil unless scope.is_a?(Hash)

      parts = []
      parts << brief_section("Scope (in)", scope["in"])
      parts << brief_section("Scope (out)", scope["out"])
      parts.compact.join("\n\n")
    end

    def lid_section
      return lid_enabled_section if lid_mode.present?
      return lid_requested_section if feature_brief["lid_requested"]

      ""
    end

    def lid_enabled_section
      <<~LID.strip
        # LID Integration

        This project uses Linked-Intent Development (LID) in `#{lid_mode}` mode.
        After this run completes, a `lid_planning` run will convert this RDR into
        LID artifacts (HLD/LLD/EARS) using the conversion table in RDR-051:
        - Problem Statement → HLD `## Problem`
        - Proposed Solution → LLD `## Approach` / `## System Design`
        - Alternatives Considered → LLD Decisions & Alternatives
        - Validation / acceptance criteria → EARS specs
        - Implementation Plan → cascade ordering

        For the issue tree you file:
        - Each issue body MUST reference relevant EARS spec IDs with `@spec`
          annotations (e.g., `@spec FEAT-NAME-001`) so implementation runs are
          LID-aware from the start
      LID
    end

    def lid_requested_section
      <<~LID.strip
        # LID Bootstrap

        The user has requested LID for this feature but the project is not yet
        LID-enabled. A `lid_planning` adoption run is needed to bootstrap the
        design tree before this feature's RDR can be tracked as intent.

        Include a note in the RDR PR description recommending LID bootstrap
        before implementation begins. Defer Step 6 (issue-tree decomposition)
        until LID adoption is confirmed — file only the RDR docs-only PR in
        this run.
      LID
    end

    # When the DB prompt is missing, render the in-code fallback with the same
    # variable substitutions as the DB template would receive.
    def fallback_prompt
      Prompts::Render.interpolate(FALLBACK_PROMPT, variables)
    end
  end
end
