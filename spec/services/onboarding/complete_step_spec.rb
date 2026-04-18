# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::CompleteStep do
  let(:account) { create(:account) }

  before do
    Onboarding::StartOnboarding.call(account: account)
  end

  describe ".call" do
    it "marks the specified step as completed" do
      described_class.call(account: account, step: "account_profile")

      step = account.onboarding_steps.find_by(step: "account_profile")
      expect(step.status).to eq("completed")
      expect(step.completed_at).to be_present
    end

    it "stores metadata on the completed step" do
      described_class.call(account: account, step: "account_profile", metadata: { key: "value" })

      step = account.onboarding_steps.find_by(step: "account_profile")
      expect(step.metadata).to eq("key" => "value")
    end

    it "advances the next step to in_progress" do
      described_class.call(account: account, step: "account_profile")

      next_step = account.onboarding_steps.find_by(step: "github_token")
      expect(next_step.status).to eq("in_progress")
    end

    it "finalizes onboarding when all steps are completed" do
      OnboardingStep::STEPS.each do |step_name|
        described_class.call(account: account, step: step_name)
      end

      expect(account.reload.onboarding_completed_at).to be_present
    end

    it "does not finalize onboarding when steps remain" do
      described_class.call(account: account, step: "account_profile")

      expect(account.reload.onboarding_completed_at).to be_nil
    end

    it "raises RecordNotFound for invalid step names" do
      expect {
        described_class.call(account: account, step: "nonexistent")
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
