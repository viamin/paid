# frozen_string_literal: true

require "digest"

module ProjectDelegation
  module IntentCheckpoint
    # Canonical revision tokens a settlement binds to (RDR-080 "the immutable
    # design and acceptance revision"). Design combines the work item's
    # linked approved design baseline (RDR-066) with its own intent content;
    # acceptance is the current recorded assessment's criteria digest
    # (RDR-071). Both re-derive deterministically at every downstream
    # boundary, so a changed token is proof the settled revision was
    # conflicted with, invalidated, or materially expanded.
    # @spec PROJECT-DELEGATION-002
    module Revisions
      DESIGN_PREFIX = "design:"
      NO_BASELINE = "none"

      def self.for(issue)
        {
          "design_revision" => design_revision_for(issue),
          "acceptance_revision" => acceptance_revision_for(issue)
        }
      end

      def self.design_revision_for(issue)
        baseline = approved_design_baseline(issue)
        digest = Digest::SHA256.hexdigest([ baseline, issue.title, issue.body ].map(&:to_s).join("\0"))
        "#{DESIGN_PREFIX}#{digest}"
      end

      def self.acceptance_revision_for(issue)
        Automation::DelegatedActionAdmission.acceptance_revision_for(
          PartialCloseouts::Assessment.call(issue)
        )
      end

      # The most recently approved design revision among the designs this
      # issue serves; an unlinked or unapproved work item binds to its own
      # intent content alone.
      def self.approved_design_baseline(issue)
        FeatureIntent.joins(:feature_intent_issues)
          .where(feature_intent_issues: { issue_id: issue.id })
          .where.not(approved_design_revision: nil)
          .order("feature_intents.id DESC")
          .pick(:approved_design_revision) || NO_BASELINE
      end
    end
  end
end
