# frozen_string_literal: true

require "rails_helper"

RSpec.describe DispatchCircuitBreakerRecoveryJob do
  describe "#perform" do
    it "transitions open breakers to half_open after timeout" do
      breaker = create(:dispatch_circuit_breaker, :open, circuit_opened_at: 10.minutes.ago)

      described_class.new.perform

      expect(breaker.reload).to be_circuit_half_open
    end

    it "does not transition open breakers before timeout" do
      breaker = create(:dispatch_circuit_breaker, :open, circuit_opened_at: 1.second.ago)

      described_class.new.perform

      expect(breaker.reload).to be_circuit_open
    end

    it "does not affect closed breakers" do
      breaker = create(:dispatch_circuit_breaker)

      described_class.new.perform

      expect(breaker.reload).to be_circuit_closed
    end
  end
end
