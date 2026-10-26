# frozen_string_literal: true

module PartialCloseouts
  # Resolves the executable portion of a closeout prerequisite without using
  # the control-plane host as evidence of execution capability.
  # @spec PARTIAL-CLOSEOUT-030
  class TechnicalPrerequisitePlan
    Result = Data.define(:status, :host, :action, :evidence) do
      def ready? = status == :ready
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, tool_name:, tool_image: nil)
      @agent_run = agent_run
      @tool_name = tool_name
      @tool_image = tool_image
    end

    def call
      return authorization_required unless tool_sidecar_authorized?

      compatible_backend
    end

    private

    attr_reader :agent_run, :tool_name, :tool_image

    def authorization_required
      Result.new(
        status: :authorization_required,
        host: nil,
        action: "An account owner must enable marketplace_tool_sidecars for this project before #{tool_name} can run.",
        evidence: scheduler_evidence
      )
    end

    def compatible_backend
      host = scheduler.candidate_hosts.first
      return unavailable unless host

      Result.new(status: :ready, host:, action: nil, evidence: scheduler_evidence)
    end

    def unavailable
      Result.new(
        status: :unavailable,
        host: nil,
        action: "Configure or restore a compatible execution host, then prepare this validation again.",
        evidence: scheduler_evidence
      )
    end

    def tool_sidecar_authorized?
      tool_image.blank? || FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)
    end

    def scheduler
      @scheduler ||= Containers::BackendScheduler.call(agent_run:)
    end

    def scheduler_evidence
      {
        "requested_tool" => tool_name,
        "tool_image" => tool_image,
        "candidate_hosts" => scheduler.candidate_hosts,
        "requirements_error" => scheduler.requirements_error,
        "compatibility_failures" => scheduler.compatibility_failures,
        "health_failures" => scheduler.health_failures
      }.compact
    end
  end
end
