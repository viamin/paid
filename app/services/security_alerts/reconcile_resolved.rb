# frozen_string_literal: true

module SecurityAlerts
  # Applies explicit upstream dispositions from an authoritative snapshot.
  # An omitted alert is not evidence that it was fixed.
  # @spec EAGER-QUEUE-013
  # @spec EAGER-QUEUE-014
  # @spec GITHUB-SYNC-019
  class ReconcileResolved
    def initialize(project, snapshot:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
      @project = project
      @snapshot = snapshot
      @source = source
    end

    def call
      return unless snapshot.authoritative_for?(project)

      resolved_alerts.each { |alert| reconcile(alert) }
    end

    private

    attr_reader :project, :snapshot, :source

    def resolved_alerts
      snapshot.alerts.group_by { |alert| alert[:number] }.filter_map do |_number, alerts|
        alerts.none? { |alert| alert[:state] == "open" } && alerts.first
      end
    end

    def reconcile(alert)
      issue = project.issues.find_by(source:, github_issue_id: synthetic_issue_id(alert))
      return unless issue
      return if issue.agent_runs.where(status: AgentRun::UNFINISHED_STATUSES).exists?

      close_issue(issue, alert) if issue.github_state == "open"
      conclude_retryable_attempts(issue, alert)
    end

    def close_issue(issue, alert)
      issue.update!(github_state: "closed", github_updated_at: Time.current, paid_state: "manual_review",
        manual_review_reason: "Upstream code-scanning alert #{alert[:state]}; scanner-verified remediation is not recorded.",
        code_scanning_disposition: alert[:state],
        code_scanning_disposition_reason: alert[:dismissed_reason] || alert[:dismissed_comment],
        code_scanning_disposition_evidence: disposition_evidence(alert))
    end

    # An authoritative GitHub conclusion closes the retryable lifecycle without
    # treating the conclusion as evidence that this PR fixed the finding.
    def conclude_retryable_attempts(issue, alert)
      issue.code_scanning_remediation_attempts.retryable_block.find_each do |attempt|
        attempt.update!(status: "upstream_resolved", blocked_reason: nil,
          evidence: attempt.evidence.merge("upstream_disposition" => disposition_evidence(alert)))
      end
    end

    def synthetic_issue_id(alert)
      return Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + alert[:number] if source == Issue::SYNTHETIC_CODE_SCANNING_SOURCE

      raise ArgumentError, "Unsupported synthetic issue source for SecurityAlerts::ReconcileResolved: #{source.inspect}"
    end

    def disposition_evidence(alert)
      alert.slice(:number, :state, :dismissed_reason, :dismissed_comment, :dismissed_by, :html_url, :updated_at)
    end
  end
end
