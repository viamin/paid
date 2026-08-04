# frozen_string_literal: true

module Runners
  # Computes quota headroom scores for runner candidates from stored
  # RunnerState quota snapshots. Used by build_runner_order to prefer
  # runners with more remaining quota when quota data is available.
  #
  # Headroom is expressed as a fraction 0.0–1.0 (remaining / limit).
  # nil means no quota data is available for that runner.
  class QuotaScore
    # Primary runner is considered low on quota below this headroom fraction.
    LOW_HEADROOM_THRESHOLD = 0.20
    # A fallback runner is a worthy alternative at or above this headroom fraction.
    FALLBACK_PREFERRED_THRESHOLD = 0.50

    Result = Struct.new(:scores, keyword_init: true) do
      def headroom_for(runner_candidate)
        scores[runner_candidate]
      end

      def primary_low?(primary_candidate)
        score = headroom_for(primary_candidate)
        score.present? && score < QuotaScore::LOW_HEADROOM_THRESHOLD
      end

      # Returns the first candidate (excluding primary) whose headroom meets
      # or exceeds FALLBACK_PREFERRED_THRESHOLD, or nil when no such runner
      # exists or the primary is not low on quota.
      def better_fallback_for(primary_candidate, candidates)
        return nil unless primary_low?(primary_candidate)

        candidates.reject { |r| r == primary_candidate }.find do |r|
          (headroom_for(r) || 0.0) >= QuotaScore::FALLBACK_PREFERRED_THRESHOLD
        end
      end
    end

    def self.call(runners:, user:)
      new(runners: runners, user: user).call
    end

    def initialize(runners:, user:)
      @runners = runners
      @user = user
    end

    def call
      states_by_name = load_runner_states
      scores = runners.each_with_object({}) do |runner_candidate, hash|
        state = states_by_name[state_name_for(runner_candidate)]
        hash[runner_candidate] = compute_headroom(state)
      end
      Result.new(scores: scores)
    end

    private

    attr_reader :runners, :user

    def load_runner_states
      names = runners.filter_map { |r| state_name_for(r) }.uniq
      return {} if names.empty?

      user.runner_states.where(runner_name: names).index_by(&:runner_name)
    end

    def state_name_for(runner_candidate)
      runner = runner_entry_for(runner_candidate)
      return runner.state_key if runner

      # Strip routing key prefix to get the bare runner_name used in RunnerState
      normalized = runner_candidate.to_s
        .delete_prefix(Runner::ROUTING_KEY_PREFIX)
        .delete_prefix(Runner::LEGACY_ROUTING_KEY_PREFIX)
      RunnerSupport.runner_key_for_agent_type(normalized)
    end

    def runner_entry_for(runner_candidate)
      return runner_candidate if runner_candidate.is_a?(Runner)
      return nil unless Runner.routing_key?(runner_candidate)

      Runner.for_identifier(user, runner_candidate)
    end

    def compute_headroom(state)
      return nil unless state

      state.quota_headroom
    end
  end
end
