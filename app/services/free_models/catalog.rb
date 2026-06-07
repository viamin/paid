# frozen_string_literal: true

module FreeModels
  class Catalog
    TierGroup = Struct.new(:tier, :label, :models, keyword_init: true)

    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      grouped_models = models.group_by { |model| model.tier.presence || "untiered" }

      (LlmModel::TIERS + [ "untiered" ]).filter_map do |tier|
        models_for_tier = grouped_models[tier]
        next if models_for_tier.blank?

        TierGroup.new(
          tier: tier,
          label: tier == "untiered" ? "Unassigned" : tier.titleize,
          models: models_for_tier
        )
      end
    end

    private

    attr_reader :project

    def models
      @models ||= LlmModel.free.by_provider(Runner::OPENROUTER_FREE_MODEL_PROVIDER).order(Arel.sql("capability_score DESC NULLS LAST"), :display_name).to_a
    end
  end
end
