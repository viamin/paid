# frozen_string_literal: true

module TechnicalPrerequisites
  # Produces a policy-aware, non-mutating preparation result for a bounded
  # validation run. Host compatibility is deliberately delegated to the
  # existing scheduler; the control plane's own Docker availability is not an
  # execution-host capability signal.
  # @spec PARTIAL-CLOSEOUT-030
  class ValidationPreflight
    Result = Data.define(:compatible_hosts, :setup_actions, :diagnostics) do
      def ready?
        compatible_hosts.present? && setup_actions.empty?
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:, scheduler: Containers::BackendScheduler, feature_flags: FeatureFlags)
      @agent_run = agent_run
      @scheduler = scheduler
      @feature_flags = feature_flags
    end

    def call
      placement = scheduler.call(agent_run: agent_run)
      Result.new(
        compatible_hosts: placement.candidate_hosts,
        setup_actions: setup_actions_for(placement),
        diagnostics: diagnostics_for(placement)
      )
    end

    private

    attr_reader :agent_run, :scheduler, :feature_flags

    def setup_actions_for(placement)
      actions = []
      actions << no_backend_action(placement) if placement.candidate_hosts.empty?
      actions << sidecar_rollout_action if tool_sidecar_requested? && !sidecars_authorized?
      actions
    end

    def no_backend_action(placement)
      { code: "no_compatible_execution_backend", message: "No compatible isolated execution backend is available.", details: placement.compatibility_failures }
    end

    def sidecar_rollout_action
      { code: "marketplace_tool_sidecars_disabled", message: "Authorize the marketplace tool-sidecar pilot for this project before selecting this tool." }
    end

    def diagnostics_for(placement)
      { compatibility_failures: placement.compatibility_failures, health_failures: placement.health_failures,
        requested_tool_sidecars: agent_run.tool_sidecar_snapshot.map { |tool| tool.slice("name", "image") } }
    end

    def tool_sidecar_requested?
      agent_run.tool_sidecar_snapshot.present?
    end

    def sidecars_authorized?
      feature_flags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)
    end
  end
end
