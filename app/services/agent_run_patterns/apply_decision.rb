# frozen_string_literal: true

module AgentRunPatterns
  class ApplyDecision
    ALLOWED_RUNNER_FIELDS = %w[tier_model_ids].freeze
    RATE_LIMIT_DURATION = 1.hour

    def self.call(...)
      new(...).call
    end

    def initialize(decision:, pattern:)
      @decision = decision
      @pattern = pattern
    end

    def call
      return decision unless decision.status == "proposed"

      RemediationDecision.transaction do
        decision.lock!
        decision.reload
        return decision unless decision.status == "proposed"

        case decision.proposed_action
        when "mark_runner_unavailable"
          apply_mark_runner_unavailable!
        when "clear_runner_field"
          apply_clear_runner_field!
        when "disable_runner_fallback"
          apply_disable_runner_fallback!
        when "file_issue"
          apply_file_issue!
        when "notify"
          apply_notify!
        else
          raise ArgumentError, "Unsupported remediation action #{decision.proposed_action.inspect}"
        end

        decision.update!(status: "applied", applied_at: Time.current)
        record_audit_event
      end

      decision
    rescue => e
      decision.update!(status: "failed") if decision.persisted? && decision.status == "proposed"
      Rails.logger.warn(
        message: "agent_run_patterns.auto_apply_failed",
        remediation_decision_id: decision.id,
        proposed_action: decision.proposed_action,
        error_class: e.class.name,
        error: e.message
      )
      decision
    end

    private

    attr_reader :decision, :pattern

    def apply_mark_runner_unavailable!
      runner = find_runner!
      state = runner.user.runner_states.find_or_create_by!(runner_name: runner.state_key) do |record|
        record.failure_count = 0
        record.circuit_state = "closed"
      end

      decision.update!(
        revert_data: {
          "handler" => "mark_runner_unavailable",
          "runner_id" => runner.id,
          "runner_state_name" => state.runner_name,
          "previous_rate_limited_until" => state.rate_limited_until&.iso8601
        }
      )

      state.mark_rate_limited!(reset_at: Time.current + RATE_LIMIT_DURATION)
    end

    def apply_clear_runner_field!
      runner = find_runner!
      field_name = decision.action_target_metadata.fetch("field_name").to_s
      raise ArgumentError, "Unsupported runner field #{field_name.inspect}" unless ALLOWED_RUNNER_FIELDS.include?(field_name)

      previous_value = runner.public_send(field_name)
      decision.update!(
        revert_data: {
          "handler" => "clear_runner_field",
          "runner_id" => runner.id,
          "field_name" => field_name,
          "previous_value" => previous_value
        }
      )

      runner.update!(field_name => nil)
    end

    def apply_disable_runner_fallback!
      runner = find_runner!
      decision.update!(
        revert_data: {
          "handler" => "disable_runner_fallback",
          "runner_id" => runner.id,
          "previous_enabled_for_fallback" => runner.enabled_for_fallback
        }
      )

      runner.update!(enabled_for_fallback: false)
    end

    def apply_file_issue!
      project = find_project!
      incident = decision.account.exception_incidents.find_or_initialize_by(fingerprint: decision.fingerprint)
      incident.assign_attributes(
        project: project,
        exception_class: "SelfHealRemediation",
        message: decision.root_cause,
        backtrace: decision.evidence_pointers.join("\n"),
        subsystem: "agent_runs",
        severity: "p2",
        action_taken: "notified",
        status: "open",
        last_occurred_at: Time.current,
        occurrence_count: [ incident.occurrence_count.to_i, decision.occurrence_count ].max,
        context: {
          "remediation_decision_id" => decision.id,
          "action_target" => {
            "type" => decision.action_target_type,
            "id" => decision.action_target_id,
            "metadata" => decision.action_target_metadata
          },
          "evidence_pointers" => decision.evidence_pointers
        }
      )
      incident.save!

      decision.update!(
        revert_data: {
          "handler" => "file_issue",
          "project_id" => project.id,
          "incident_id" => incident.id
        }
      )

      ExceptionHandler::IssueFiler.call(incident: incident, project: project)
      decision.update!(revert_data: decision.revert_data.merge(
        "github_issue_url" => incident.reload.github_issue_url,
        "github_issue_number" => incident.github_issue_number
      ))
    end

    def apply_notify!
      Notifications::Publish.call(
        account: decision.account,
        source: Notify::NOTIFICATION_SOURCE,
        subject: decision.account,
        severity: :warning,
        title: "Self-heal notification: #{decision.root_cause}",
        description: "Remediation action #{decision.proposed_action.humanize} was applied as notify-only.",
        metadata: { remediation_decision_id: decision.id },
        action_url: "/remediation_decisions/#{decision.id}",
        nav_section: "dashboard"
      )
      decision.update!(revert_data: { "handler" => "notify" })
    end

    def find_runner!
      runner = Runner.find(decision.runner_id)
      raise ActiveRecord::RecordNotFound, "Runner does not belong to decision account" unless runner.user.account_id == decision.account_id

      runner
    end

    def find_project!
      project = Project.find(decision.action_target_id)
      raise ActiveRecord::RecordNotFound, "Project does not belong to decision account" unless project.account_id == decision.account_id

      project
    end

    def record_audit_event
      subject = find_runner_for_audit || find_project_for_audit || decision.account

      Audit::RecordEvent.call(
        account: decision.account,
        action: "self_heal.remediation_applied",
        subject: subject,
        metadata: {
          remediation_action: decision.proposed_action,
          remediation_decision_id: decision.id,
          target_label: decision.action_target_label,
          details: [
            "Root cause: #{decision.root_cause}",
            "Fingerprint: #{decision.fingerprint}",
            "Confidence: #{decision.confidence}"
          ]
        }
      )
    end

    def find_runner_for_audit
      return find_runner! if decision.runner_target?

      nil
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def find_project_for_audit
      return nil unless decision.action_target_type == "project"

      find_project!
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end
end
