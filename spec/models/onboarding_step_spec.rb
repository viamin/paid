# frozen_string_literal: true

require "rails_helper"

RSpec.describe OnboardingStep do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
  end

  describe "validations" do
    subject { build(:onboarding_step) }

    it { is_expected.to validate_presence_of(:step) }
    it { is_expected.to validate_inclusion_of(:step).in_array(described_class::STEPS) }
    it { is_expected.to validate_presence_of(:position) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    it "validates uniqueness of step scoped to account" do
      existing = create(:onboarding_step)
      duplicate = build(:onboarding_step, account: existing.account, step: existing.step)
      expect(duplicate).not_to be_valid
    end
  end

  describe "#complete!" do
    it "marks the step as completed with timestamp and metadata" do
      step = create(:onboarding_step, :in_progress)
      freeze_time do
        step.complete!(token_id: 42)
        expect(step.reload).to have_attributes(
          status: "completed",
          completed_at: Time.current,
          metadata: { "token_id" => 42 }
        )
      end
    end
  end

  describe "#skip!" do
    it "marks the step as skipped with timestamp" do
      step = create(:onboarding_step, :in_progress)
      freeze_time do
        step.skip!
        expect(step.reload).to have_attributes(
          status: "skipped",
          completed_at: Time.current
        )
      end
    end
  end

  describe "#mark_in_progress!" do
    it "transitions a pending step to in_progress" do
      step = create(:onboarding_step, status: "pending")
      step.mark_in_progress!
      expect(step.reload.status).to eq("in_progress")
    end

    it "does not change a completed step" do
      step = create(:onboarding_step, :completed)
      step.mark_in_progress!
      expect(step.reload.status).to eq("completed")
    end
  end

  describe "scopes" do
    let(:account) { create(:account) }

    before do
      create(:onboarding_step, account: account, step: "account_profile", position: 0, status: "completed", completed_at: Time.current)
      create(:onboarding_step, account: account, step: "github_token", position: 1, status: "in_progress")
      create(:onboarding_step, account: account, step: "first_project", position: 2, status: "pending")
    end

    it ".ordered returns steps by position" do
      steps = account.onboarding_steps.ordered
      expect(steps.map(&:step)).to eq(%w[account_profile github_token first_project])
    end

    it ".completed returns only completed steps" do
      expect(account.onboarding_steps.completed.map(&:step)).to eq(%w[account_profile])
    end

    it ".pending returns only pending steps" do
      expect(account.onboarding_steps.pending.map(&:step)).to eq(%w[first_project])
    end
  end
end
