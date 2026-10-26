# frozen_string_literal: true

module PartialCloseouts
  # Projects the existing runner-placement and marketplace authorization
  # contracts into an operator-safe prerequisite explanation.  In particular,
  # this deliberately asks Paid's configured backends rather than inspecting
  # the web process' Docker socket: that socket says nothing about where an
  # isolated AgentRun can execute.
  #
  # @spec PARTIAL-CLOSEOUT-030
  class ExecutionPrerequisiteReadiness
    Result = Data.define(:status, :hosts, :actions) do
      def ready?
        status == "ready"
      end
    end

    def self.call(...) = new(...).call

    def initialize(agent_run:, scheduler: Containers::BackendScheduler, flags: FeatureFlags)
      @agent_run = agent_run
      @scheduler = scheduler
      @flags = flags
    end

    def call
      placement = scheduler.call(agent_run:)
      return unavailable(placement) if placement.candidate_hosts.empty?
      return authorization_required(placement) if sidecar_requested? && !sidecars_authorized?

      Result.new(status: "ready", hosts: placement.candidate_hosts, actions: [])
    end

    private

    attr_reader :agent_run, :flags, :scheduler

    def sidecar_requested?
      agent_run.tool_sidecar_snapshot.present?
    end

    def sidecars_authorized?
      flags.enabled?(:marketplace_tool_sidecars, project: agent_run.project)
    end

    def unavailable(placement)
      failures = placement.compatibility_failures.merge(placement.health_failures)
      actions = failures.map { |host, reason| "Configure or select #{host}: #{reason}" }
      actions << "Add a compatible isolated execution backend before retrying." if actions.empty?
      Result.new(status: "unavailable", hosts: [], actions: actions)
    end

    def authorization_required(placement)
      Result.new(
        status: "authorization_required",
        hosts: placement.candidate_hosts,
        actions: [ "Enable marketplace_tool_sidecars for this tenant's approved pilot, then retry this unchanged pinned run." ]
      )
    end
  end
end
