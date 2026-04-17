# frozen_string_literal: true

module QualityAlerts
  # Checks quality gates for a project after metric collection and publishes
  # notifications when thresholds are breached. Respects per-user notification
  # preferences to determine who receives alerts.
  #
  # @example
  #   QualityAlerts::CheckGate.call(project: project)
  class CheckGate
    NOTIFICATION_SOURCE = "quality_gate_breach"

    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      result = Evaluate.call(project: project)

      if result[:breached]
        publish_alert(result)
      else
        resolve_existing_alert
      end

      result
    end

    private

    attr_reader :project

    def publish_alert(result)
      breach_summary = result[:breaches].map { |b| b[:description] }.join("; ")

      Notifications::Publish.call(
        account: project.account,
        source: NOTIFICATION_SOURCE,
        subject: project,
        severity: alert_severity(result[:breaches]),
        title: "Quality gate triggered for #{project.name}",
        description: breach_summary,
        metadata: build_metadata(result),
        action_url: "/projects/#{project.id}/quality_dashboard",
        nav_section: "projects"
      )

      Rails.logger.warn(
        message: "quality_alerts.gate_breached",
        project_id: project.id,
        breach_count: result[:breaches].size,
        sample_size: result[:sample_size]
      )
    end

    def resolve_existing_alert
      Notifications::Resolve.call(
        account: project.account,
        source: NOTIFICATION_SOURCE,
        subject: project
      )
    end

    def build_metadata(result)
      {
        breaches: result[:breaches],
        recent_runs: result[:recent_runs],
        remediation_actions: result[:remediation_actions],
        evaluated_at: result[:evaluated_at],
        window_hours: result[:window_hours],
        sample_size: result[:sample_size]
      }
    end

    def alert_severity(breaches)
      composite_breach = breaches.find { |b| b[:metric] == "composite_score" }
      return :error if composite_breach && composite_breach[:current] < composite_breach[:threshold] * 0.5

      breaches.size >= 3 ? :error : :warning
    end
  end
end
