# frozen_string_literal: true

require "temporalio/activity"

module Activities
  # Base class for all Temporal activities in this application.
  #
  # Inherits from Temporalio::Activity::Definition as per the temporalio gem v1.2.0 API.
  # Activities must implement an `execute` method which will be called by the Temporal worker.
  #
  # Temporal serializes inputs through JSON, converting symbol keys to strings.
  # InputNormalizer ensures subclasses always receive symbol-keyed hashes.
  class BaseActivity < Temporalio::Activity::Definition
    module InputNormalizer
      def execute(input)
        super(input.is_a?(Hash) ? input.deep_symbolize_keys : input)
      end
    end

    def self.inherited(subclass)
      super
      subclass.prepend(InputNormalizer)
    end

    protected

    def logger
      Rails.logger
    end

    def update_workflow_state(workflow_id, attributes)
      WorkflowState.upsert(
        attributes.merge(temporal_workflow_id: workflow_id),
        unique_by: :temporal_workflow_id
      )
    end

    def add_phase_label(client, project, issue_number, label)
      client.add_labels_to_issue(project.full_name, issue_number, [ label ])
    rescue GithubClient::Error => e
      logger.warn(
        message: "pr_review.add_label_failed",
        project_id: project.id,
        pr_number: issue_number,
        label: label,
        error: e.message
      )
    end

    def track_phase(agent_run_id:, phase_key:, phase_group:, agent_run: nil, metadata: {}, started_at: Time.current)
      status = "completed"
      result = yield
      result
    rescue => e
      status = "failed"
      metadata = metadata.merge(
        error_class: e.class.name,
        error_message: e.message.to_s.truncate(500)
      )
      raise
    ensure
      if agent_run_id.present?
        tracked_agent_run = agent_run || AgentRun.find_by(id: agent_run_id)
        record_phase(
          agent_run: tracked_agent_run,
          phase_key: phase_key,
          phase_group: phase_group,
          started_at: started_at,
          finished_at: Time.current,
          status: status,
          metadata: metadata
        )
      end
    end

    def record_phase(agent_run:, phase_key:, phase_group:, started_at:, finished_at:, status: "completed", metadata: {})
      return unless agent_run

      AgentRunPhase.record!(
        agent_run: agent_run,
        phase_key: phase_key,
        phase_group: phase_group,
        started_at: started_at,
        finished_at: finished_at,
        status: status,
        metadata: metadata
      )
    rescue => recording_error
      logger.warn(
        message: "agent_run_phase.record_failed",
        agent_run_id: agent_run.id,
        phase_key: phase_key,
        phase_group: phase_group,
        error_class: recording_error.class.name,
        error_message: recording_error.message.to_s.truncate(500)
      )
    end
  end
end
