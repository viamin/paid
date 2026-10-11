# frozen_string_literal: true

module Projects
  # Settings-aware structural readiness evaluation for contract-driven work
  # (RDR-074). Given a project's settings and a repository checkout, returns
  # the prerequisites the project is missing (CI, test harness, test
  # command) without any AI judgment or I/O beyond reading the checkout.
  #
  # Phase 1 (this segment) only computes gaps; it does not persist them,
  # surface them in the Inbox, or remediate them — see
  # docs/intent/project-readiness/project-readiness-design.md.
  #
  # @spec PROJECT-READINESS-001
  module Readiness
    # A single missing prerequisite. `evidence` carries the structural facts
    # (paths checked, ecosystem, candidates) a human or a later remediation
    # run needs to act on the gap — never free-text AI reasoning.
    Gap = Data.define(:kind, :description, :evidence) do
      def to_h
        { kind: kind, description: description, evidence: evidence }
      end
    end

    # The full evaluation outcome. Persistence-ready: Phase 2's Inbox lane
    # and Phase 3's bootstrap run path both consume `gaps` and `evaluated_at`
    # directly.
    Result = Data.define(:gaps, :evaluated_at) do
      def satisfied?
        gaps.empty?
      end

      def to_h
        { gaps: gaps.map(&:to_h), evaluated_at: evaluated_at.iso8601 }
      end
    end

    def self.call(project:, repo_path:)
      Evaluate.call(project: project, repo_path: repo_path)
    end
  end
end
