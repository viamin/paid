# frozen_string_literal: true

module Issues
  # Re-evaluates the issues that were parked because a dependency was still
  # unresolved, once that dependency resolves (#4640).
  #
  # The dependency-blocked parking state is a hold, not a verdict: while the
  # blocking work is open, the issue cannot be scheduled, and once it is
  # resolved the issue must return to the pipeline instead of waiting for a
  # human to notice it. The hold is only lifted when the dependent has no
  # unresolved dependency left.
  #
  # @spec MANUAL-REVIEW-RECOVERY-003
  class ReleaseDependencyBlockedDependents
    def self.call(...) = new(...).call

    def initialize(dependency_issue:)
      @dependency_issue = dependency_issue
    end

    def call
      parked_dependents.each { |issue| release(issue) }
    end

    private

    attr_reader :dependency_issue

    def parked_dependents
      Issue.where(id: dependent_ids, paid_state: "manual_review")
        .where("issues.manual_review_reason LIKE ?", "%#{Issue::DEPENDENCY_BLOCKED_REASON_MARKER}%")
        .to_a
    end

    def dependent_ids
      IssueDependency.where(depends_on_issue_id: dependency_issue.id).pluck(:issue_id)
    end

    def release(issue)
      return if Issues::CloseoutStatus.prerequisite_labels(issue).any?

      issue.update!(paid_state: "completed")
      Rails.logger.info(
        message: "issues.dependency_blocked_dependent_released",
        component: "agent_execution",
        issue_id: issue.id,
        project_id: issue.project_id,
        issue_number: issue.github_number,
        dependency_issue_id: dependency_issue.id
      )
    end
  end
end
