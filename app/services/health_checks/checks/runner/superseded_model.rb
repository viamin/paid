# frozen_string_literal: true

module HealthChecks
  module Checks
    module Runner
      class SupersededModel < HealthChecks::Check
        include ModelCheckSupport

        self.scope = :runner

        def self.network? = false

        def call
          LlmModel::TIERS.filter_map do |tier|
            model = resolved_tier_model(tier)
            next unless model

            replacement = replacement_model_for(model, tier)
            next unless replacement

            build_finding(
              severity: :info,
              message: "Runner #{subject.display_name} resolves superseded model #{model.model_id} for #{tier} tier; consider #{replacement.model_id}."
            )
          end
        end

        private

        def replacement_model_for(model, tier)
          return if model.capability_score.nil?

          LlmModel.active
            .where(provider: model.provider, tier: tier)
            .where.not(id: model.id)
            .where.not(capability_score: nil)
            .where("capability_score > ?", model.capability_score)
            .where("expires_at IS NULL OR expires_at > ?", Time.current)
            .where("(metadata->>'below_quality_bar')::boolean IS NOT TRUE")
            .order(capability_score: :desc, model_id: :asc)
            .find { |candidate| !compatibility_for(candidate.model_id)&.unsupported? }
        end
      end
    end
  end
end
