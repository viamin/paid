# frozen_string_literal: true

require "base64"
require "json"

module ChatSessions
  class RunnerModelOptions
    Option = Data.define(:label, :value, :runner_id, :model_id)

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
      models_by_id = LlmModel.active.where(model_id: model_ids).index_by(&:model_id)
      runners.flat_map { |runner| options_for_runner(runner, models_by_id) }
    end

    private

    attr_reader :runners

    def options_for_runner(runner, models_by_id)
      [ automatic_option(runner) ] + configured_model_ids(runner).filter_map do |model_id|
        model = models_by_id[model_id]
        model_option(runner, model_id, model) if model
      end
    end

    def automatic_option(runner)
      option(runner, nil, "#{runner.display_name} — Automatic")
    end

    def model_option(runner, model_id, model)
      label = model&.display_name || model_id
      option(runner, model_id, "#{runner.display_name} — #{label}")
    end

    def option(runner, model_id, label)
      Option.new(label, encode(runner.id, model_id), runner.id, model_id)
    end

    def model_ids
      runners.flat_map { |runner| configured_model_ids(runner) }.uniq
    end

    def configured_model_ids(runner)
      [ runner.direct_outbound_model_id, *runner.tier_model_ids.to_h.values, *tier_model_ids(runner) ].compact_blank.uniq
    end

    def tier_model_ids(runner)
      runner.tier_models.values.filter_map { |entry| entry["model_id"] if entry.is_a?(Hash) }
    end

    def encode(runner_id, model_id)
      Base64.urlsafe_encode64([ runner_id, model_id ].to_json, padding: false)
    end
  end
end
