# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::SkipStep do
  let(:account) { create(:account) }

  before do
    Onboarding::StartOnboarding.call(account: account)
    # Complete steps up to configure_defaults
    %w[account_profile github_token first_project].each do |step|
      Onboarding::CompleteStep.call(account: account, step: step)
    end
  end

  describe ".call" do
    it "skips the configure_defaults step" do
      described_class.call(account: account, step: "configure_defaults")

      step = account.onboarding_steps.find_by(step: "configure_defaults")
      expect(step.status).to eq("skipped")
    end

    it "finalizes onboarding when the last step is skipped" do
      described_class.call(account: account, step: "configure_defaults")

      expect(account.reload.onboarding_completed_at).to be_present
    end

    it "raises ArgumentError for non-skippable steps" do
      expect {
        described_class.call(account: account, step: "github_token")
      }.to raise_error(ArgumentError, /cannot be skipped/)
    end
  end
end
