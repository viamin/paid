# frozen_string_literal: true

module PromptReviews
  # Approves a pending evolved prompt version and promotes it to be the
  # prompt's current version.
  #
  # @example
  #   PromptReviews::Approve.call(
  #     prompt_version: evolved_version,
  #     reviewer: current_user,
  #     notes: "LGTM"
  #   )
  class Approve
    attr_reader :prompt_version, :reviewer, :notes, :promote

    def initialize(prompt_version:, reviewer:, notes: nil, promote: true)
      @prompt_version = prompt_version
      @reviewer = reviewer
      @notes = notes
      @promote = promote
    end

    def self.call(...)
      new(...).approve
    end

    def approve
      validate!

      prompt = prompt_version.prompt
      approved_at = Time.current
      prompt.with_lock do
        raise ArgumentError, "prompt version is no longer pending review" unless prompt_version.reload.pending_review?

        prompt_version.update!(
          review_status: "approved",
          reviewed_by_user: reviewer,
          reviewed_at: approved_at,
          review_notes: notes
        )
        prompt.update!(current_version: prompt_version) if promote
      end
      complete_recovery_action!(approved_at) if promote
      prompt_version
    end

    private

    def validate!
      raise ArgumentError, "reviewer is required" unless reviewer
      raise ArgumentError, "prompt version is not pending review" unless prompt_version.pending_review?
    end

    def complete_recovery_action!(approved_at)
      recovery_action = QualityRecoveryAction
        .where(project: prompt_version.prompt.project, action_type: "prompt_evolution", status: "executing")
        .for_prompt_version_rollout(prompt_version.id)
        .order(created_at: :desc)
        .first
      return unless recovery_action

      recovery_action.complete!(recovery_action.result, executed_at: approved_at)
    end
  end
end
