# frozen_string_literal: true

module HealthChecks
  module Checks
    module Runner
      module ModelCheckSupport
        private

        def resolved_tier_result(tier)
          @resolved_tier_results ||= {}
          @resolved_tier_results[tier] ||= Runners::ResolveTierModel.call(
            runner: subject,
            tier: tier,
            user: subject.user
          )
        end

        def resolved_tier_model(tier)
          result = resolved_tier_result(tier)
          return unless result&.success?
          return if result.model_id.blank?

          @resolved_tier_models ||= {}
          @resolved_tier_models[tier] ||= LlmModel.find_by(model_id: result.model_id)
        end

        def compatibility_for(model_id)
          Runners::ModelCompatibility.call(
            runner_key: subject.runner_key,
            model_id: model_id,
            auth_type: subject.auth_type,
            provider_runtime: subject.agent_harness_runner_runtime
          )
        end

        def build_finding(severity:, message:)
          HealthChecks::Finding.new(
            check: self.class.name,
            scope: self.class.scope,
            severity: severity,
            message: message
          )
        end
      end
    end
  end
end
