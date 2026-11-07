# frozen_string_literal: true

module ProjectDelegation
  # Computes one RDR-080 pilot-metric window for a project: human Inbox
  # decisions per completed issue, median and p90 decision time,
  # completed-issue rate, and settled completions later reversed. Joins are
  # revision aware — the result pins the intent revision of every joined work
  # item — and exclusions carry reason codes. Pure query/compute; persistence
  # belongs to RecordPilotMetrics.
  #
  # @spec PROJECT-DELEGATION-007
  class PilotMetrics
    AUTO_RELEASED_EXCLUSION = "auto_released"

    Result = Data.define(
      :window_started_at, :window_ended_at,
      :inbox_decisions, :completed_issues, :decisions_per_completed_issue,
      :median_decision_seconds, :p90_decision_seconds,
      :admitted_issues, :completed_issue_rate,
      :reversal_count, :reversal_rate, :delegated_reversal_count,
      :exclusions, :revisions
    )

    def self.call(project:, window_started_at:, window_ended_at:)
      new(project:, window_started_at:, window_ended_at:).call
    end

    def initialize(project:, window_started_at:, window_ended_at:)
      @project = project
      @window_started_at = window_started_at
      @window_ended_at = window_ended_at
    end

    def call
      Result.new(
        window_started_at: window_started_at,
        window_ended_at: window_ended_at,
        inbox_decisions: decided_notifications.size,
        completed_issues: completed_issue_ids.size,
        decisions_per_completed_issue: ratio(decided_notifications.size, completed_issue_ids.size),
        median_decision_seconds: percentile(decision_seconds, 0.5),
        p90_decision_seconds: percentile(decision_seconds, 0.9),
        admitted_issues: admitted_issue_ids.size,
        completed_issue_rate: ratio(completed_issue_ids.size, admitted_issue_ids.size),
        reversal_count: reversed_issue_ids.size,
        reversal_rate: ratio(reversed_issue_ids.size, completed_issue_ids.size),
        delegated_reversal_count: delegated_reversed_issue_ids.size,
        exclusions: exclusions,
        revisions: revisions
      )
    end

    private

    attr_reader :project, :window_started_at, :window_ended_at

    # A human Inbox decision is a blocking notification (it cannot self-resolve)
    # on the project or one of its issues that a human resolved or dismissed in
    # the window. Automatic reconciliation releases are excluded with a reason
    # code so the pilot never credits machinery with a human decision.
    def decided_notifications
      @decided_notifications ||= candidate_notifications.reject { |notification| notification.metadata["released_by"].present? }
    end

    def candidate_notifications
      @candidate_notifications ||= Notification.blocking
        .where("COALESCE(resolved_at, dismissed_at) >= ? AND COALESCE(resolved_at, dismissed_at) < ?",
          window_started_at, window_ended_at)
        .merge(project_subject_scope.or(issue_subject_scope))
        .includes(:subject)
        .select { |notification| subject_in_scope?(notification.subject) }
    end

    def project_subject_scope
      Notification.where(subject_type: "Project", subject_id: project.id)
    end

    def issue_subject_scope
      Notification.where(subject_type: "Issue", subject_id: project.issues.select(:id))
    end

    # Defense-in-depth on the polymorphic join: subjects are filtered in SQL,
    # and any row that still resolves outside the project's scope is dropped
    # rather than counted.
    def subject_in_scope?(subject)
      subject == project || (subject.is_a?(Issue) && subject.project_id == project.id)
    end

    def decision_seconds
      @decision_seconds ||= decided_notifications.map do |notification|
        (notification.resolved_at || notification.dismissed_at) - notification.created_at
      end.sort
    end

    # An issue counts as completed when its Paid state reached `completed`
    # inside the window (the completion write is the row's latest update).
    def completed_issue_ids
      @completed_issue_ids ||= project.issues
        .where(paid_state: "completed")
        .where(updated_at: window_started_at...window_ended_at)
        .ids
    end

    # Admitted work: distinct issues the project's delivery touched in the
    # window, via a first run. The completed-issue rate is measured over this
    # population, not over every open request.
    def admitted_issue_ids
      @admitted_issue_ids ||= project.issues
        .joins(:agent_runs)
        .where(agent_runs: { created_at: window_started_at...window_ended_at })
        .distinct.ids
    end

    # A settled completion later reversed: the reopen-review parking the issue
    # lifecycle already records. Attributable to delegated work when the
    # reversed issue carried a bounded delegated authorization.
    def reversed_issue_ids
      @reversed_issue_ids ||= project.issues
        .where(paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
        .where(updated_at: window_started_at...window_ended_at)
        .ids
    end

    def delegated_reversed_issue_ids
      @delegated_reversed_issue_ids ||= reversed_issue_ids & BoundedDelegatedAction.where(issue_id: reversed_issue_ids).pluck(:issue_id)
    end

    def exclusions
      auto_released = candidate_notifications.size - decided_notifications.size
      return [] unless auto_released.positive?

      [ { "reason" => AUTO_RELEASED_EXCLUSION, "count" => auto_released } ]
    end

    # Revision-aware joins: the snapshot pins the intent revision of every
    # joined work item, so later reads can prove which revisions produced the
    # numbers and refuse comparisons across changed intent.
    def revisions
      joined_ids = (completed_issue_ids + admitted_issue_ids + reversed_issue_ids).uniq
      revision_pairs = project.issues.where(id: joined_ids).order(:id).map do |issue|
        "#{issue.id}:#{PartialCloseouts::Assessment.intent_revision_for(issue)}"
      end

      {
        "joined_issue_ids" => joined_ids.sort,
        "issues_digest" => Digest::SHA256.hexdigest(revision_pairs.join("\0"))
      }
    end

    def ratio(numerator, denominator)
      return nil if denominator.nil? || denominator.zero?

      (numerator.to_f / denominator).round(4)
    end

    def percentile(sorted_values, fraction)
      return nil if sorted_values.empty?

      rank = (fraction * (sorted_values.size - 1)).round
      sorted_values[rank].round(2)
    end
  end
end
