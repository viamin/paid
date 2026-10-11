# frozen_string_literal: true

module Onboarding
  # Verifies credentials whose provider-specific runtime cannot be checked from
  # the API-key form alone. The initial chat remains available while the
  # harness performs its normal runner health check in the background.
  # @spec ONBOARD-CHAT-003
  class ValidateChatApiKeyJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    def perform(runner_id)
      runner = Runner.find(runner_id)
      result = AgentHarness.check_provider(
        RunnerSupport.harness_runner_key_for(runner.runner_key).to_sym,
        timeout: Onboarding::ConfigureChatRunner::HEALTH_CHECK_TIMEOUT,
        provider_runtime: runner.agent_harness_runner_runtime
      )
      log_result(runner, result)
    rescue AgentHarness::Error => e
      Rails.logger.warn(
        message: "onboarding.chat_api_key_validation.unavailable",
        runner_id: runner_id,
        error_class: e.class.name
      )
    end

    private

    def log_result(runner, result)
      Rails.logger.info(
        message: "onboarding.chat_api_key_validation.completed",
        runner_id: runner.id,
        status: result[:status].to_s,
        error_category: result[:error_category].to_s.presence
      )
    end
  end
end
