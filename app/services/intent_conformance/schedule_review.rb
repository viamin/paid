# frozen_string_literal: true

module IntentConformance
  class ScheduleReview # @spec INTENT-CONFORMANCE-010
    MAX_PENDING_PER_PROJECT = 8
    STALE_ENQUEUE_AFTER = 1.hour

    def self.call(...) = new(...).call

    def initialize(project:, issue:, pr_head_sha:)
      @project, @issue, @pr_head_sha = project, issue, pr_head_sha
    end

    def call
      return unless applicable? && !current_verdict?

      existing_schedule ? reschedule(existing_schedule) : schedule_new_review
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    private

    attr_reader :project, :issue, :pr_head_sha

    def applicable?
      issue.is_pull_request? && feature_intent&.released? && feature_intent.approved_design_revision.present? &&
        pr_head_sha.present? && FeatureFlags.enabled?(:approved_intent_amendments, project: project)
    end

    def feature_intent = @feature_intent ||= issue.feature_intent

    def current_verdict?
      IntentConformanceVerdict.current_for(issue: issue, head_sha: pr_head_sha)&.current_for?(
        pr_head_sha: pr_head_sha, approved_design_revision: feature_intent.approved_design_revision
      )
    end

    def existing_schedule
      IntentConformanceReviewSchedule.find_by(issue:, pr_head_sha:, approved_design_revision: feature_intent.approved_design_revision)
    end

    def schedule_new_review
      return cap_reached if pending_cap_reached?

      enqueue(IntentConformanceReviewSchedule.create!(
        project:, issue:, pr_head_sha:, approved_design_revision: feature_intent.approved_design_revision, enqueued_at: Time.current
      ))
    end

    def reschedule(schedule)
      return unless schedule.completed? || schedule.pending? && schedule.enqueued_at < STALE_ENQUEUE_AFTER.ago

      schedule.update!(status: "pending", completed_at: nil, enqueued_at: Time.current)
      enqueue(schedule)
    end

    def pending_cap_reached?
      IntentConformanceReviewSchedule.where(project:, status: %w[pending running]).count >= MAX_PENDING_PER_PROJECT
    end

    def cap_reached
      Rails.logger.warn(message: "intent_conformance.review_schedule_capped", project_id: project.id, issue_id: issue.id, pr_head_sha:,
        approved_design_revision: feature_intent.approved_design_revision)
      nil
    end

    def enqueue(schedule)
      IntentConformance::ReviewJob.perform_later(project.id, schedule.id)
      Rails.logger.info(message: "intent_conformance.review_scheduled", project_id: project.id, issue_id: issue.id, pr_head_sha:,
        approved_design_revision: feature_intent.approved_design_revision, schedule_id: schedule.id)
      schedule
    end
  end
end
