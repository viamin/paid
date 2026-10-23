# frozen_string_literal: true

module Runners
  # Which catalog tiers an owner's configured runners cannot satisfy.
  #
  # Feasibility depends only on the owner's live runner configuration — never
  # on the project or the issues being considered — so a single instance
  # resolves it once per owner and reuses that answer for the rest of the
  # batch. A caller evaluating one scope takes the default fresh instance and
  # pays one resolution per scope; a caller walking many projects owned by the
  # same person (the dashboard eligibility breakdown) shares one instance so
  # the per-project pass does not re-query runner configuration per project.
  #
  # The memo is keyed by owner id and lives only as long as the instance, so
  # nothing outlives the pass that created it: every pass re-derives
  # feasibility from live configuration and a newly capable runner clears its
  # own exclusion (AUTO-PICK-QUEUE-011). Build one per pass; never store it.
  class TierFeasibility
    def initialize
      @infeasible_tiers_by_owner_id = {}
    end

    # Catalog tiers that no kept, agent-run-enabled, container-executable
    # runner of +user+ can satisfy. An ownerless project has no runner
    # configuration to probe, so nothing is reported infeasible and the
    # dispatch-time tier filter stays the final gate.
    # @spec AUTO-PICK-QUEUE-011
    def infeasible_tiers(user)
      return [] if user.nil?
      return @infeasible_tiers_by_owner_id[user.id] if @infeasible_tiers_by_owner_id.key?(user.id)

      @infeasible_tiers_by_owner_id[user.id] = resolve(user)
    end

    private

    def resolve(user)
      runners = user.runners.kept_only.for_agent_runs
        .where(runner_key: RunnerSupport.container_executable_runner_keys)
        .ordered.to_a

      LlmModel::TIERS.reject do |tier|
        Runners::TierCapability.any_supports_tier?(runners, tier, user: user)
      end
    end
  end
end
