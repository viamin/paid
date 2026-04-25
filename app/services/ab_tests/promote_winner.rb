# frozen_string_literal: true

module AbTests
  # Promotes the winning variant's prompt version as the new default
  # for the associated prompt.
  #
  # When the prompt has +requires_review+ enabled, the winning variant is
  # NOT auto-promoted. Instead, it is flagged as pending review so a human
  # can approve/reject via the review queue before it becomes active.
  # The winning variant can be pre-marked pending by the caller; this
  # service will normalize non-reviewed variants into pending state so
  # downstream review UI works consistently.
  #
  # @example
  #   AbTests::PromoteWinner.call(ab_test: completed_test)
  class PromoteWinner
    attr_reader :ab_test

    def initialize(ab_test:)
      @ab_test = ab_test
    end

    def self.call(...)
      new(...).promote
    end

    def promote
      validate!

      prompt = ab_test.prompt
      winning_version = ab_test.winner_variant.prompt_version

      if prompt.requires_review?
        gate_for_review(winning_version)
      else
        promote_immediately(prompt, winning_version)
      end

      winning_version
    end

    # True when the winning version was queued for human review rather than
    # promoted immediately. Callers can use this to surface the right UI hint.
    def gated?
      return false unless ab_test&.prompt&.requires_review?

      ab_test.winner_variant&.prompt_version&.pending_review?
    end

    private

    def validate!
      raise ArgumentError, "A/B test is not completed" unless ab_test.completed?
      raise ArgumentError, "A/B test has no winner" unless ab_test.winner_variant
    end

    def promote_immediately(prompt, winning_version)
      # Use with_lock to prevent concurrent version updates (consistent with
      # Prompt#create_version! which also locks before updating current_version).
      prompt.with_lock do
        prompt.update!(current_version: winning_version)
      end
      complete_recovery_action!(winning_version)
    end

    def gate_for_review(winning_version)
      return if winning_version.pending_review?
      # Don't overwrite an existing review outcome; approved/rejected versions
      # stay as-is and the caller can decide what to do next (e.g., re-run).
      return if winning_version.under_review?

      winning_version.update!(review_status: "pending")
    end

    def complete_recovery_action!(winning_version)
      recovery_action = QualityRecoveryAction
        .where(project: ab_test.prompt.project, action_type: "prompt_evolution", status: "executing")
        .for_ab_test(ab_test.id)
        .for_prompt_version_rollout(winning_version.id)
        .order(created_at: :desc)
        .first
      return unless recovery_action

      recovery_action.complete!(recovery_action.result)
    end
  end
end
