# frozen_string_literal: true

module Runners
  # Tier-capability query shared by dispatch (Activities::RunAgentActivity)
  # and the pre-dispatch gates — enqueue-time validation
  # (Activities::CreateAgentRunActivity) and auto-pick candidate filtering
  # (Automation::Strategies::AutoPick::DefaultCandidateSource).
  #
  # Extracted from RunAgentActivity#runner_supports_tier? (#4093) so tier
  # feasibility can be resolved where the retry cap and other pre-dispatch
  # gates already run, instead of only after a run has been dispatched and a
  # container branch/workspace planned. The activity-side filter remains the
  # final gate because feasibility can drift during a run's lifetime (runner
  # deleted, model deactivated).
  #
  # A runner candidate supports a requested tier when it is direct-outbound
  # (brings its own model from config and bypasses the LlmModel tier
  # catalog), has an explicit tier_models entry, its bound provider exposes
  # one, or the standard-provider catalog default resolves a model for the
  # tier (Runners::DefaultTierModelIds).
  class TierCapability
    class << self
      # @spec RUNNER-FALLBACK-001
      def supports_tier?(runner_candidate, tier, user:)
        new(user: user).supports_tier?(runner_candidate, tier)
      end

      # True when at least one candidate supports the requested tier. A
      # blank tier never constrains dispatch, so it is always satisfiable.
      def any_supports_tier?(runner_candidates, tier, user:)
        return true if tier.blank?

        capability = new(user: user)
        Array(runner_candidates).any? { |candidate| capability.supports_tier?(candidate, tier) }
      end

      # Base dispatch candidates for a run: the bound runner (or intended
      # agent type) plus configured fallbacks, restricted to
      # container-executable runner keys, falling back to the goal default
      # runner when the primary cannot run. Mirrors the candidate
      # construction Activities::RunAgentActivity#build_runner_order feeds
      # its tier filter, minus the attempt-time-only state (retry caps,
      # quota headroom, time windows) that cannot be known before dispatch.
      # The result may be a superset of the final dispatch order, so callers
      # use it to detect "no runner could ever satisfy this tier" — never
      # to assert an exact order.
      # @spec RUNNER-FALLBACK-010
      def dispatch_candidates(agent_run:, user_settings:)
        new(user: user_settings&.user).dispatch_candidates(
          agent_run: agent_run,
          user_settings: user_settings
        )
      end
    end

    def initialize(user:)
      @user = user
      @runner_entry_cache = {}
    end

    # @spec RUNNER-FALLBACK-001
    def supports_tier?(runner_candidate, tier)
      return true if tier.blank?

      # Direct-outbound runners bring their own model from config and bypass
      # the tier catalog entirely, so they are always compatible with any
      # requested tier.
      return true if direct_outbound_runner?(runner_candidate)

      runner_entry = runner_entry_for(runner_candidate)
      return true if runner_entry&.supports_tier?(tier)

      runner_key = runner_entry&.runner_key || RunnerSupport.runner_key_for_agent_type(runner_candidate)
      resolution_runner = runner_entry || Runner.new(runner_key: runner_key)
      provider = user&.provider_for(resolution_runner)
      return true if provider&.supports_tier?(tier)

      effective_auth_type = provider&.auth_type.presence || resolution_runner.auth_type.to_s.presence ||
        Runners::DefaultTierModelIds::DEFAULT_AUTH_TYPE
      Runners::DefaultTierModelIds.call(runner_key: runner_key, auth_type: effective_auth_type)[tier].present?
    end

    def dispatch_candidates(agent_run:, user_settings:)
      candidates = primary_candidates(agent_run, user_settings)
      if candidates.empty? && fallback_to_default_runner?(agent_run)
        candidates = default_candidates(agent_run, user_settings)
      end
      candidates.compact_blank.uniq
    end

    # Direct-outbound runners (opencode, kilocode, pi, omp) bring their own
    # model from config and bypass the LlmModel tier catalog, so they are
    # compatible with every requested tier. A free-policy runner is excluded
    # because it still requires a tier-resolved free model. Uses the runner
    # entry when available; falls back to the resolved runner key so bare
    # agent-type candidates (e.g. "opencode") are still recognized.
    def direct_outbound_runner?(runner_candidate)
      runner_entry = runner_entry_for(runner_candidate)
      return false if runner_entry&.free_model_policy?

      runner_key = runner_entry&.runner_key || RunnerSupport.runner_key_for_agent_type(runner_candidate)

      runner_entry&.requires_direct_outbound? ||
        Runners::DefaultTierModelIds::DIRECT_OUTBOUND_RUNNER_KEYS.include?(runner_key)
    end

    private

    attr_reader :user

    def primary_candidates(agent_run, user_settings)
      if agent_run.runner
        runners = [ agent_run.runner.routing_key ]
        if user_settings&.fallback_enabled
          runners.concat(user_settings.fallback_priority_for(
            primary_runner: agent_run.runner.routing_key, identifiers: true
          ))
        end
        executable_candidates(runners)
      elsif user_settings&.fallback_enabled
        fallback_runners = user_settings.fallback_priority_for(
          primary_runner: RunnerSupport.runner_key_for_agent_type(agent_run.agent_type),
          identifiers: true
        )
        executable_candidates([ agent_run.agent_type, *Array(fallback_runners) ])
      else
        executable_candidates([ agent_run.agent_type ])
      end
    end

    def default_candidates(agent_run, user_settings)
      first_key = RunnerSupport.container_executable_runner_keys.first
      default_fallback = first_key ? RunnerSupport.agent_type_for(first_key) : "claude_code"

      [
        user_settings&.default_runner_identifier_for_goal(agent_run.goal),
        default_fallback
      ]
    end

    def fallback_to_default_runner?(agent_run)
      return true if agent_run.runner.present?

      runner_key = Runner.runner_key_for_agent_type(agent_run.agent_type)
      AgentRun::AGENT_TYPES.include?(agent_run.agent_type) &&
        RunnerSupport.supported_runner_key?(runner_key)
    end

    # Keeps only candidates that map to a container-executable runner key.
    # Routing-key identifiers resolve through the persisted Runner entry so
    # the executability test sees the real runner_key, mirroring how
    # RunAgentActivity's runner_command_key canonicalizes candidates.
    def executable_candidates(candidates)
      candidates.select { |candidate| container_executable?(candidate) }
    end

    def container_executable?(runner_candidate)
      runner_key = runner_entry_for(runner_candidate)&.runner_key ||
        RunnerSupport.runner_key_for_agent_type(runner_candidate)
      RunnerSupport.container_executable_runner_key?(runner_key)
    end

    def runner_entry_for(runner_candidate)
      return runner_candidate if runner_candidate.is_a?(Runner)
      return nil unless user
      return nil unless Runner.routing_key?(runner_candidate)

      cache_key = [ user.id, runner_candidate ]
      return @runner_entry_cache[cache_key] if @runner_entry_cache.key?(cache_key)

      @runner_entry_cache[cache_key] = Runner.for_identifier(user, runner_candidate)
    end
  end
end
