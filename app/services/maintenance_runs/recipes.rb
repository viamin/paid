# frozen_string_literal: true

module MaintenanceRuns
  # Catalog of maintenance recipe objectives (RDR-075). A recipe supplies a
  # reusable objective; a manual run may use a recipe or supply a nonblank
  # original question — a catalog entry is not required to investigate a
  # user-directed maintenance question. Tool-assisted evidence collectors and
  # their version pins belong to #4330, not this registry.
  # @spec MAINT-011 MAINT-046
  module Recipes
    Recipe = Data.define(:key, :version, :name, :objective_instructions)

    UNNECESSARY_CODE = Recipe.new(
      key: "unnecessary_code",
      version: "1",
      name: "Unnecessary code",
      objective_instructions: <<~INSTRUCTIONS.chomp
        Investigate unnecessary code: unused code and dependencies, duplication,
        complexity, unnecessary abstractions, and obsolete behavior. Identify
        candidates with evidence, then verify each against repository intent —
        framework callbacks, reflection, external APIs, intentional
        independence, and compatibility obligations must be considered before
        claiming code is removable.
      INSTRUCTIONS
    ).freeze

    INTENT_TRACEABILITY = Recipe.new(
      key: "intent_traceability",
      version: "1",
      name: "Intent traceability",
      objective_instructions: <<~INSTRUCTIONS.chomp
        Audit RDR-to-issue traceability through the shared design-artifact
        reconciliation results; do not build or infer a separate RDR inventory,
        issue catalog, scheduler, or structural verifier. Scope may name RDRs,
        repository paths, revisions, or related workflows.

        Distinguish merged artifact intent from proposed open design-PR intent.
        Disclose unresolved scope and incomplete remote coverage rather than
        treating either as evidence of absence. Report missing, partial,
        unlinked or stale, deferred, and unverifiable trees, plus probable
        duplicate work and ownership conflicts. Preserve stored and
        cross-repository associations as counterevidence: stale metadata or
        absent native children does not prove a tree is missing, and superseded
        artifacts or valid shared trees must not prompt duplicate filing.

        Use agent_harness only to assess whether issue scope covers an
        implementation plan, existing work already owns it, or repository
        ownership is coherent. Record supporting evidence and contrary evidence
        for every conclusion. This is report-only: do not create, edit, label,
        transfer, close, or otherwise change issues or pull requests. A later,
        separately authorized repair may link existing work, repair metadata,
        or draft bounded missing tasks.
      INSTRUCTIONS
    ).freeze

    ALL = {
      UNNECESSARY_CODE.key => UNNECESSARY_CODE,
      INTENT_TRACEABILITY.key => INTENT_TRACEABILITY
    }.freeze

    class << self
      def fetch(key)
        ALL.fetch(key)
      end

      def keys
        ALL.keys
      end

      def exists?(key)
        ALL.key?(key)
      end
    end
  end
end
