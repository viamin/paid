# frozen_string_literal: true

module TechnicalPrerequisites
  # Projects the existing placement and rollout decisions into an actionable
  # Inbox-ready result. A missing Docker socket in the browser/control-plane
  # process is intentionally not an input to this decision.
  # @spec PARTIAL-CLOSEOUT-030
  class CapabilityInspection
    Result = Data.define(:host, :compatible_hosts, :failures, :requirements_error, :tool_sidecars_enabled, :setup_action) do
      def runnable? = compatible_hosts.any? && setup_action.nil?
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, scheduler: Containers::BackendScheduler)
      @agent_run = agent_run
      @scheduler = scheduler
    end

    def call
      schedule = scheduler.call(agent_run:)
      hosts = schedule.candidate_hosts
      Result.new(
        host: hosts.first,
        compatible_hosts: hosts,
        failures: schedule.compatibility_failures.merge(schedule.health_failures),
        requirements_error: schedule.requirements_error,
        tool_sidecars_enabled: tool_sidecars_enabled?,
        setup_action: setup_action_for(schedule)
      )
    end

    private

    attr_reader :agent_run, :scheduler

    def tool_sidecars_enabled?
      FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)
    end

    def setup_action_for(schedule)
      return "Resolve execution requirements: #{schedule.requirements_error}" if schedule.requirements_error.present?
      return "Configure or restore a compatible execution backend for this project." if schedule.candidate_hosts.empty?
      return unless agent_run.tool_sidecar_snapshot.any? && !tool_sidecars_enabled?

      "Request scoped pilot authorization to enable marketplace_tool_sidecars for this project; execution capability does not authorize the rollout."
    end
  end
end
