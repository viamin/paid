# frozen_string_literal: true

module PartialCloseouts
  # Computes the deterministic part of a technical-prerequisite recovery. It
  # deliberately asks the configured scheduler about execution hosts instead
  # of inspecting the web process's Docker socket: the two are different
  # authorities and only the scheduler can select a run-safe backend.
  #
  # @spec PARTIAL-CLOSEOUT-031
  class TechnicalPrerequisiteReadiness
    Result = Data.define(:status, :action, :message, :candidate_hosts, :failures) do
      def ready? = status == :ready
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, requires_tool_sidecar: false, scheduler: Containers::BackendScheduler)
      @agent_run = agent_run
      @requires_tool_sidecar = requires_tool_sidecar
      @scheduler = scheduler
    end

    def call
      return tool_rollout_required if requires_tool_sidecar && !FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)

      scheduled = scheduler.call(agent_run: agent_run)
      return unavailable(scheduled) if scheduled.candidate_hosts.empty?

      Result.new(
        status: :ready,
        action: :start_validation,
        message: "Start a bounded validation on #{scheduled.candidate_hosts.first}.",
        candidate_hosts: scheduled.candidate_hosts,
        failures: failures_for(scheduled)
      )
    end

    private

    attr_reader :agent_run, :requires_tool_sidecar, :scheduler

    def tool_rollout_required
      Result.new(
        status: :authorization_required,
        action: :enable_tool_sidecar_pilot,
        message: "Marketplace tool sidecars are disabled for this project. An authorized pilot owner must enable marketplace_tool_sidecars before this validation can run.",
        candidate_hosts: [],
        failures: {}
      )
    end

    def unavailable(scheduled)
      Result.new(
        status: :unavailable,
        action: :configure_compatible_backend,
        message: scheduled.requirements_error || "No compatible execution backend is currently available.",
        candidate_hosts: [],
        failures: failures_for(scheduled)
      )
    end

    def failures_for(scheduled)
      scheduled.compatibility_failures.merge(scheduled.health_failures)
    end
  end
end
