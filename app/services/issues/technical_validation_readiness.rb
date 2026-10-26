# frozen_string_literal: true

module Issues
  # Inspects Paid execution infrastructure, never the operator's browser or
  # agent workspace. A missing local Docker socket is therefore not evidence
  # that no compatible backend exists.
  # @spec PARTIAL-CLOSEOUT-030
  class TechnicalValidationReadiness
    Result = Data.define(:code, :message, :tool_entry, :evidence) do
      def ready? = code.nil?
    end

    def self.call(...) = new(...).call

    def initialize(project:, tool_entry_id: nil)
      @project = project
      @tool_entry_id = tool_entry_id
    end

    def call
      return missing_tool_flag unless tool_entry_id.blank? || FeatureFlags.enabled?(:marketplace_tool_sidecars, project:)

      tool = selected_tool
      return Result.new(code: :tool_not_authorized, message: "Select an active authorized marketplace tool before starting validation.", tool_entry: nil, evidence: base_evidence) if tool_entry_id && !tool

      hosts = project.account.docker_hosts.placement_ready_for_restricted_agent_runs.order(:id)
      return Result.new(code: :no_compatible_backend, message: "No compatible Paid execution backend is ready. Configure or approve a restricted execution host, then retry.", tool_entry: tool, evidence: base_evidence) if hosts.empty?

      Result.new(code: nil, message: nil, tool_entry: tool, evidence: base_evidence.merge("candidate_hosts" => hosts.pluck(:identifier)))
    end

    private

    attr_reader :project, :tool_entry_id

    def selected_tool
      project.account.marketplace_entries.active.with_entry_type("tool").find_by(id: tool_entry_id)
    end

    def missing_tool_flag
      Result.new(code: :tool_sidecars_disabled, message: "Marketplace tool sidecars are disabled for this project. An authorized rollout owner must enable the scoped pilot before this tool validation can start.", tool_entry: nil, evidence: base_evidence)
    end

    def base_evidence
      { "checked_at" => Time.current.iso8601, "project_id" => project.id, "tool_entry_id" => tool_entry_id,
        "tool_sidecars_enabled" => FeatureFlags.enabled?(:marketplace_tool_sidecars, project:) }
    end
  end
end
