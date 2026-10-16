# frozen_string_literal: true

require "base64"
require "json"

module ChatSessions
  class RunnerModelOptions
    Option = Data.define(:label, :value, :runner_id, :model_id, :tier)

    def self.options_for(runners)
      new(runners).options
    end

    def self.resolve(runners:, value:)
      options_for(runners).find { |option| option.value == value }
    end

    def initialize(runners)
      @runners = runners
    end

    def options
      runners.flat_map { |runner| options_for_runner(runner) }
    end

    private

    attr_reader :runners

    def options_for_runner(runner)
      # @spec CHAT-SESSION-PREFERENCES-003
      CuratedModelOptions.for_runner(runner).map do |curated|
        option(runner, curated.model_id, "#{runner.display_name} — #{curated.label}", curated.tier)
      end
    end

    def option(runner, model_id, label, tier)
      Option.new(label, encode(runner.id, model_id), runner.id, model_id, tier)
    end

    def encode(runner_id, model_id)
      Base64.urlsafe_encode64([ runner_id, model_id ].to_json, padding: false)
    end
  end
end
