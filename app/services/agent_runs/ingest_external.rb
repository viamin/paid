# frozen_string_literal: true

module AgentRuns
  class IngestExternal
    EXTERNAL_AGENT_TYPE_BY_SOURCE = {
      "github_copilot" => "copilot",
      "cursor" => "cursor",
      "devin" => "devin",
      "factory" => "factory",
      "internal_agent_workflows" => "internal_agent"
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:, attributes:, initiating_user: nil)
      @project = project
      @attributes = attributes.to_h.deep_symbolize_keys
      @initiating_user = initiating_user
    end

    def call
      validate!

      AgentRun.create!(agent_run_attributes)
    end

    private

    attr_reader :project, :attributes, :initiating_user

    def validate!
      raise ArgumentError, "external_source_key is required" if external_source_key.blank?
      raise ArgumentError, "external_run_key is required" if external_run_key.blank?

      Interop::AdoptionModeGuard.enforce!(project: project, action: :ingest_external_runs)

      unless project.external_execution_enabled_for?(external_source_key)
        raise ArgumentError, "#{external_source_key} is not enabled for external execution ingestion on this project"
      end

      if attributes[:issue_id].present? && issue.nil?
        raise ArgumentError, "issue not found"
      end

      return unless issue && issue.project_id != project.id

      raise ArgumentError, "issue must belong to the same project"
    end

    def agent_run_attributes
      {
        project: project,
        issue: issue,
        initiating_user: initiating_user,
        agent_type: attributes[:agent_type].presence || EXTERNAL_AGENT_TYPE_BY_SOURCE.fetch(external_source_key),
        status: attributes[:status].presence || "completed",
        goal: attributes[:goal].presence || "create_pr",
        focus: attributes[:focus].presence || "general",
        trigger_type: "manual",
        custom_prompt: attributes[:custom_prompt],
        source_pull_request_number: attributes[:source_pull_request_number],
        started_at: attributes[:started_at],
        completed_at: attributes[:completed_at],
        duration_seconds: attributes[:duration_seconds],
        tokens_input: attributes[:tokens_input],
        tokens_output: attributes[:tokens_output],
        cost_cents: attributes[:cost_cents],
        pull_request_url: attributes[:pull_request_url],
        pull_request_number: attributes[:pull_request_number],
        result_commit_sha: attributes[:result_commit_sha],
        execution_origin: "external",
        external_source_key: external_source_key,
        external_run_key: external_run_key,
        adoption_mode_snapshot: project.adoption_mode,
        external_metadata: attributes[:external_metadata].is_a?(Hash) ? attributes[:external_metadata] : {}
      }.compact
    end

    def external_source_key
      @external_source_key ||= attributes[:external_source_key].to_s.presence
    end

    def external_run_key
      @external_run_key ||= attributes[:external_run_key].to_s.presence
    end

    def issue
      return @issue if defined?(@issue)

      @issue = if attributes[:issue].is_a?(Issue)
        attributes[:issue]
      elsif attributes[:issue_id].present?
        project.issues.find_by(id: attributes[:issue_id])
      end
    end
  end
end
