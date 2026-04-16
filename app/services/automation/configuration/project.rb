# frozen_string_literal: true

module Automation
  module Configuration
    # Aggregates every automation-configuration value object for a single
    # {::Project}. Build once per scan/evaluation and pass around instead
    # of the raw {::Project} record, so strategy code can consume the
    # normalized config without reaching into nested settings hashes or
    # checking individual boolean columns.
    #
    # Each sub-config is a frozen {::Data} value object; this top-level
    # wrapper is itself a +Data.define+ so equality, deconstruction, and
    # freezing work out of the box.
    class Project < ::Data.define(
      :auto_pick,
      :auto_continue,
      :auto_review,
      :auto_merge
    )
      def self.from(project)
        new(
          auto_pick: AutoPick.from_project(project),
          auto_continue: AutoContinue.from_project(project),
          auto_review: AutoReview.from_project(project),
          auto_merge: AutoMerge.from_project(project)
        )
      end

      # Convenience accessor for the ReviewSettings nested inside the
      # auto-review config. Callers that only need review-method lookups
      # can reach it without drilling through +auto_review+.
      def review_settings
        auto_review.review_settings
      end
    end
  end
end
