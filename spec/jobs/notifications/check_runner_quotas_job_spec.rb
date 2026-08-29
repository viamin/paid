# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::CheckRunnerQuotasJob do
  describe "#perform" do
    it "evaluates the quota rule with all runners in a single batch" do
      create(:runner)
      allow(Notifications::Rules::RunnerQuotaExhausted).to receive(:call)
      allow(Notifications::Rules::RunnerSubscriptionAuthIneligible).to receive(:call)

      described_class.perform_now

      expect(Notifications::Rules::RunnerQuotaExhausted).to have_received(:call) do |scope:|
        expect(scope).to be_an(Array)
        expect(scope).to all(be_a(Runner))
      end
      expect(Notifications::Rules::RunnerSubscriptionAuthIneligible).to have_received(:call) do |scope:|
        expect(scope).to be_an(Array)
        expect(scope).to all(be_a(Runner))
      end
    end

    it "eager-loads runner_states to avoid N+1" do
      create(:runner)
      allow(Notifications::Rules::RunnerQuotaExhausted).to receive(:call)
      allow(Notifications::Rules::RunnerSubscriptionAuthIneligible).to receive(:call)

      described_class.perform_now

      expect(Notifications::Rules::RunnerQuotaExhausted).to have_received(:call) do |scope:|
        scope.each do |runner|
          expect(runner.user.association(:runner_states)).to be_loaded
        end
      end
      expect(Notifications::Rules::RunnerSubscriptionAuthIneligible).to have_received(:call)
    end

    it "uses the maintenance queue" do
      expect(described_class.new.queue_name).to eq("maintenance")
    end
  end
end
