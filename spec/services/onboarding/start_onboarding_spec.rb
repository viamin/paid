# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::StartOnboarding do
  let(:account) { create(:account) }

  describe ".call" do
    it "creates onboarding steps for the account" do
      described_class.call(account: account)

      steps = account.onboarding_steps.ordered
      expect(steps.map(&:step)).to eq(%w[account_profile github_token first_project configure_defaults])
      expect(steps.map(&:position)).to eq([ 0, 1, 2, 3 ])
    end

    it "marks the first step as in_progress" do
      described_class.call(account: account)

      first_step = account.onboarding_steps.ordered.first
      expect(first_step.status).to eq("in_progress")
    end

    it "marks remaining steps as pending" do
      described_class.call(account: account)

      remaining = account.onboarding_steps.where.not(position: 0)
      expect(remaining.pluck(:status).uniq).to eq([ "pending" ])
    end

    it "sets trial_ends_at for trial accounts" do
      freeze_time do
        described_class.call(account: account)
        expect(account.reload.trial_ends_at).to eq(14.days.from_now)
      end
    end

    it "does not set trial_ends_at for non-trial accounts" do
      account.update!(plan: "professional")
      described_class.call(account: account)
      expect(account.reload.trial_ends_at).to be_nil
    end

    it "is idempotent - does not create duplicate steps" do
      described_class.call(account: account)
      expect { described_class.call(account: account) }.not_to change { account.onboarding_steps.count }
    end
  end
end
