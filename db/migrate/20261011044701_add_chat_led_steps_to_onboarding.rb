# frozen_string_literal: true

class AddChatLedStepsToOnboarding < ActiveRecord::Migration[8.1]
  # @spec ONBOARD-CHAT-001
  STEPS = %w[account_profile chat_api_key github_token first_project integrations configure_defaults].freeze

  def up
    Account.where(onboarding_completed_at: nil).find_each do |account|
      steps = account.onboarding_steps.index_by(&:step)
      next if steps.empty?

      add_missing_step(account, steps, "chat_api_key", after: "account_profile")
      add_missing_step(account, steps, "integrations", after: "first_project")
      account.onboarding_steps.each { |step| step.update_columns(position: STEPS.index(step.step)) }
      promote_chat_key_step(steps)
    end
  end

  def down
    OnboardingStep.where(step: %w[chat_api_key integrations]).delete_all
    OnboardingStep.find_each do |step|
      position = %w[account_profile github_token first_project configure_defaults].index(step.step)
      step.update_columns(position: position) if position
    end
  end

  private

  def add_missing_step(account, steps, name, after:)
    return if steps[name]

    reference = steps.fetch(after)
    steps[name] = account.onboarding_steps.create!(step: name, position: reference.position + 1, status: "pending")
  end

  def promote_chat_key_step(steps)
    github_token = steps["github_token"]
    chat_api_key = steps["chat_api_key"]
    in_progress_step = steps.values.find(&:in_progress?)
    return unless github_token && chat_api_key&.pending? && in_progress_step
    return unless in_progress_step.position >= github_token.position

    in_progress_step.update_columns(status: "pending")
    chat_api_key.update_columns(status: "in_progress")
  end
end
