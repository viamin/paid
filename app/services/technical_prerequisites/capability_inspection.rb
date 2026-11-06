# frozen_string_literal: true

module TechnicalPrerequisites
  # Projects the existing placement and rollout decisions into an actionable
  # Inbox-ready result. A missing Docker socket in the browser/control-plane
  # process is intentionally not an input to this decision.
  # @spec PARTIAL-CLOSEOUT-032
  class CapabilityInspection
    Result = Data.define(:host, :compatible_hosts, :failures, :requirements_error, :tool_sidecars_enabled, :setup_action) do
      def runnable? = compatible_hosts.any? && setup_action.nil?
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, performance_recipe: nil, scheduler: Containers::BackendScheduler)
      @agent_run = agent_run
      @performance_recipe = performance_recipe
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

    attr_reader :agent_run, :performance_recipe, :scheduler

    def tool_sidecars_enabled?
      FeatureFlags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)
    end

    # The recipe's declared environment is reviewed provenance, not proof: this
    # validation path only ever provisions the run's bare isolated container
    # plus attached tool sidecars, so a recipe that explicitly attests it needs
    # a browser-visible environment can never be satisfied here. Blocking it at
    # inspection, the same way an unauthorized tool sidecar is blocked, keeps
    # the requested label from being recorded as satisfied provenance.
    def setup_action_for(schedule)
      return "Resolve execution requirements: #{schedule.requirements_error}" if schedule.requirements_error.present?
      return "Configure or restore a compatible execution backend for this project." if schedule.candidate_hosts.empty?
      return browser_environment_unavailable_action if requires_browser?
      return unless agent_run.tool_sidecar_snapshot.any? && !tool_sidecars_enabled?

      "Request scoped pilot authorization to enable marketplace_tool_sidecars for this project; execution capability does not authorize the rollout."
    end

    def requires_browser?
      performance_recipe.present? && ActiveModel::Type::Boolean.new.cast(performance_recipe["requires_browser"])
    end

    def browser_environment_unavailable_action
      "This validation path provisions an isolated container only; it cannot satisfy a recipe that requires a browser-visible environment."
    end
  end
end
