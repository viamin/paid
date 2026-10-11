# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AddChatLedStepsToOnboarding" do
  # @spec ONBOARD-CHAT-001
  it "defines the chat-led onboarding order" do
    expect(OnboardingStep::STEPS).to eq(
      %w[account_profile chat_api_key github_token first_project integrations configure_defaults]
    )
  end
end
