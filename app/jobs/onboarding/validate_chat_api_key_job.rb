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
      invalidate_bootstrap(runner) if authentication_failure?(result)
      log_result(runner, result)
    rescue AgentHarness::Error => e
      Rails.logger.warn(
        message: "onboarding.chat_api_key_validation.unavailable",
        runner_id: runner_id,
        error_class: e.class.name
      )
    end

    private

    def authentication_failure?(result)
      result[:status].to_s == "error" && result[:error_category].to_s == "authentication"
    end

    def invalidate_bootstrap(runner)
      runner.with_lock do
        step = onboarding_step_for(runner)
        return unless step&.completed? && step.metadata["runner_id"] == runner.id

        ActiveRecord::Base.transaction do
          destroy_welcome_sessions(runner)
          provider_api_key = runner.provider_api_key
          runner.destroy!
          provider_api_key.destroy!
          restore_onboarding_step(step)
        end
      end
    end

    def onboarding_step_for(runner)
      runner.user.account.onboarding_steps.lock.find_by(step: "chat_api_key")
    end

    def destroy_welcome_sessions(runner)
      runner.chat_sessions.where("metadata @> ?", { onboarding: true }.to_json).find_each(&:destroy!)
    end

    def restore_onboarding_step(step)
      step.update!(status: "in_progress", completed_at: nil, metadata: {})
      step.account.onboarding_steps.find_by(position: step.position + 1, status: "in_progress")&.update!(status: "pending")
    end

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
