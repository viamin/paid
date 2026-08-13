# frozen_string_literal: true

module PromptReviews
  # Rejects a pending evolved prompt version. The version is retained for
  # audit/history but is not promoted to current.
  #
  # @example
  #   PromptReviews::Reject.call(
  #     prompt_version: evolved_version,
  #     reviewer: current_user,
  #     notes: "Removes important safety guidance"
  #   )
  class Reject
    attr_reader :prompt_version, :reviewer, :notes

    def initialize(prompt_version:, reviewer:, notes:)
      @prompt_version = prompt_version
      @reviewer = reviewer
      @notes = notes
    end

    def self.call(...)
      new(...).reject
    end

    def reject
      validate!

      prompt_version.prompt.with_lock do
        raise ArgumentError, "prompt version is no longer pending review" unless prompt_version.reload.pending_review?

        prompt_version.update!(
          review_status: "rejected",
          reviewed_by_user: reviewer,
          reviewed_at: Time.current,
          review_notes: notes
        )
      end
      fail_recovery_action!
      record_audit_event
      prompt_version
    end

    private

    def record_audit_event
      Audit::RecordEvent.call(
        action: "prompt_version.rejected",
        actor: reviewer,
        subject: prompt_version,
        metadata: {
          prompt_slug: prompt_version.prompt.slug,
          version: prompt_version.version,
          notes: notes
        }
      )
    rescue StandardError => e
      Rails.logger.error(
        message: "prompt_reviews.audit_failed",
        action: "rejected",
        error_class: e.class.name,
        error_message: e.message
      )
    end

    def validate!
      raise ArgumentError, "reviewer is required" unless reviewer
      raise ArgumentError, "rejection notes are required" if notes.to_s.strip.empty?
      raise ArgumentError, "prompt version is not pending review" unless prompt_version.pending_review?
    end

    def fail_recovery_action!
      recovery_action = QualityRecoveryAction
        .where(project: prompt_version.prompt.project, action_type: "prompt_evolution", status: "executing")
        .for_prompt_version_rollout(prompt_version.id)
        .order(created_at: :desc)
        .first
      return unless recovery_action

      recovery_action.fail!(status: "review_rejected", prompt_version_id: prompt_version.id)
    end
  end
end
