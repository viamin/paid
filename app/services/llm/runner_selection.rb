# frozen_string_literal: true

module Llm
  class RunnerSelection
    def self.candidates(user:)
      return [] unless user

      runners = user.runners.kept_only.for_chat.ordered.to_a
      settings = user.settings
      primary = resolve(runners, settings&.kb_chat_runner)
      explicit_runner = Runner.routing_key?(settings&.kb_chat_runner)
      primary ||= resolve(runners, settings&.default_runner_identifier) || runners.first unless explicit_runner
      return [] unless primary || (explicit_runner && settings&.fallback_enabled?)
      return [ primary ] unless settings&.fallback_enabled?

      configured = Array(settings.kb_chat_fallback_runners).filter_map { |identifier| resolve(runners, identifier) }
      [ primary, *(configured + runners).select(&:enabled_for_fallback?) ].compact.uniq
    end

    def self.resolve(runners, identifier)
      runners.find { |runner| runner.routing_key == identifier || runner.runner_key == identifier }
    end
    private_class_method :resolve

    def self.available_candidates(user:) # @spec LLM-ROUTING-007
      runners = candidates(user: user)
      states = user.runner_states.where(runner_name: runners.map(&:state_key)).index_by(&:runner_name)
      runners.select do |runner|
        state = states[runner.state_key]
        state&.check_circuit_recovery!(timeout: user.settings.circuit_breaker_timeout_seconds)
        !state&.unavailable?
      end
    end
  end
end
