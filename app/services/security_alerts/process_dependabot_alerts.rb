# frozen_string_literal: true

module SecurityAlerts
  # Reconciles GitHub's alert evidence without scheduling a second remediation
  # loop. Reasons are copied only from authoritative GitHub evidence; PR absence
  # remains explicitly unknown. # @spec DEPENDABOT-COVERAGE-001
  class ProcessDependabotAlerts
    def initialize(project)
      @project = project
    end

    def call(alerts)
      seen_numbers = alerts.map { |alert| alert.fetch(:number) }
      close_missing_alerts(seen_numbers)
      alerts.each { |alert| reconcile(alert) }
    end

    private

    attr_reader :project

    def close_missing_alerts(numbers)
      project.dependabot_alert_coverages.where.not(alert_number: numbers).find_each do |coverage|
        coverage.update!(alert_state: "resolved")
      end
    end

    def reconcile(alert)
      coverage = existing_coverage(alert) || project.dependabot_alert_coverages.build(alert_number: alert.fetch(:number))
      previous_state = coverage.coverage_state
      coverage.assign_attributes(attributes_for(alert, coverage))
      coverage.uncovered_since = uncovered_since_for(coverage, previous_state)
      coverage.save!
      escalate!(coverage) if coverage.escalation_due?
    end

    def existing_coverage(alert)
      project.dependabot_alert_coverages.find_by(alert_number: alert.fetch(:number)) ||
        project.dependabot_alert_coverages.find_by(
          dependency_ecosystem: alert.fetch(:dependency_ecosystem), dependency_name: alert.fetch(:dependency_name),
          advisory_ghsa_id: alert.fetch(:advisory_ghsa_id), manifest_path: alert[:manifest_path]
        )
    end

    def attributes_for(alert, coverage)
      state, reason = coverage_state_for(alert, coverage)
      {
        account: project.account, alert_number: alert.fetch(:number),
        dependency_name: alert.fetch(:dependency_name), dependency_ecosystem: alert.fetch(:dependency_ecosystem),
        manifest_path: alert[:manifest_path], advisory_ghsa_id: alert.fetch(:advisory_ghsa_id),
        advisory_cve_id: alert[:advisory_cve_id], alert_state: alert.fetch(:state, "open"),
        coverage_state: state, reason: reason, remediation_pull_requests: alert.fetch(:remediation_pull_requests, []),
        evidence: alert.fetch(:evidence, {}), first_detected_at: coverage.first_detected_at || Time.current,
        last_detected_at: Time.current
      }
    end

    # An alert that lost its open remediation PR receives the documented grace
    # period from the transition, not from first_detected_at: a PR that was
    # open for thirty days and then closed unmerged would otherwise escalate on
    # the next poll. # @spec DEPENDABOT-COVERAGE-001
    def uncovered_since_for(coverage, previous_state)
      return nil if coverage.effective_pr_open?

      if previous_state == "effective_pr_open"
        Time.current
      else
        coverage.uncovered_since.presence || coverage.first_detected_at || Time.current
      end
    end

    def coverage_state_for(alert, coverage)
      return [ "accepted", "operator_accepted" ] if coverage.accepted?
      return [ alert[:coverage_state], alert.fetch(:reason, "unknown") ] if alert[:coverage_state].present?
      return [ "no_patched_version", "no_patched_version" ] if alert[:first_patched_version].blank?

      remediation = Array(alert[:remediation_pull_requests]).first
      return [ "awaiting_processing", "unknown" ] unless remediation

      return [ "effective_pr_open", "open_remediation_pr" ] if remediation[:state] == "open"
      return [ "effective_pr_closed_unmerged", "closed_unmerged" ] if remediation[:state] == "closed"

      [ "merged_still_vulnerable", "merged_pr_requires_scanner_confirmation" ]
    end

    def escalate!(coverage)
      Notifications::Publish.call(
        account: project.account, source: "dependabot_alert_coverage", subject: coverage,
        severity: :error, blocking: true, nav_section: "projects",
        title: "Dependabot alert lacks an effective remediation",
        description: "#{coverage.dependency_name} / #{coverage.advisory_ghsa_id}: #{coverage.reason}.",
        metadata: { project_id: project.id, alert_number: coverage.alert_number, reason: coverage.reason }
      )
      coverage.update!(escalated_at: Time.current)
    end
  end
end
