# frozen_string_literal: true

module Automation
  module Strategies
    class AutoReview
      # Immutable input for {Strategies::AutoReview}. Wraps the scan payload
      # emitted by +ScanPaidPrsActivity+ with helpers that plugin classes
      # can use without drilling into nested Hashes.
      #
      # Signals are intentionally provider-neutral: they describe "what the
      # scan observed" (phase, per-trigger hashes, counters) rather than
      # raw GitHub state. A future signal collector
      # (RDR-023 Layer 2) will populate this structure without changing
      # the downstream plugin contract.
      class Signals < ::Data.define(
        :issue_id,
        :pr_number,
        :phase,
        :draft,
        :triggers,
        :counters,
        :owner_reviewer_login,
        :labels_to_remove
      )
        EMPTY_TRIGGERS = [].freeze
        EMPTY_COUNTERS = {}.freeze
        EMPTY_LABELS = [].freeze

        PHASES = %w[draft ready escalated restarted].freeze

        class << self
          def from_scan(scan)
            scan = (scan || {}).deep_symbolize_keys
            triggers = Array(scan[:triggers]).map { |t| t.is_a?(Hash) ? t.deep_symbolize_keys.freeze : {}.freeze }.freeze

            new(
              issue_id: scan[:issue_id],
              pr_number: scan[:pr_number],
              phase: scan[:phase]&.to_s,
              draft: scan[:draft] == true,
              triggers: triggers,
              counters: build_counters(scan).freeze,
              owner_reviewer_login: scan[:owner_reviewer_login],
              labels_to_remove: Array(scan[:labels_to_remove]).freeze
            )
          end

          private

          def build_counters(scan)
            {
              draft_review: scan[:current_draft_review_count],
              followup: scan[:current_followup_count],
              review_goal_retry: scan[:current_review_goal_retry_count]
            }
          end
        end

        def draft_phase? = phase == "draft" || phase == "restarted"
        def ready_phase? = phase == "ready"
        def escalated_phase? = phase == "escalated"

        def trigger(type)
          triggers.find { |t| t[:type].to_s == type.to_s }
        end

        def trigger?(type)
          !trigger(type).nil?
        end

        def trigger_types
          triggers.map { |t| t[:type].to_s }
        end

        def trigger_types_excluding(*types)
          excluded = types.map(&:to_s)
          trigger_types - excluded
        end

        def draft_review_count = counters[:draft_review]
        def followup_count = counters[:followup]
        def review_goal_retry_count = counters[:review_goal_retry]
      end
    end
  end
end
