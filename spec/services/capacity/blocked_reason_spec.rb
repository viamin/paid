# frozen_string_literal: true

require "rails_helper"

RSpec.describe Capacity::BlockedReason do
  describe "registry" do
    it "exposes canonical codes with safe summaries and hints" do
      expected_codes = %w[
        docker_unavailable
        docker_slow
        docker_low_confidence
        docker_memory_exhausted
        auto_mode_disabled_for_deployment
        auto_mode_degraded
        cooldown_active
        unrelated_workload
        oom_history
        policy_unknown
      ]

      expect(described_class::REASONS.keys.map(&:to_s)).to include(*expected_codes)
    end

    it "returns a fallback policy_unknown reason for unknown codes" do
      reason = described_class[:definitely_not_a_real_code]

      expect(reason.code).to eq("policy_unknown")
      expect(reason.summary).to be_present
      expect(reason.hint).to be_present
    end

    it "never exposes backend identifiers, container names, or commands" do
      described_class::REASONS.each do |code, reason|
        expect(reason.summary).not_to match(/docker\.sock|exec |sudo |\/var\/run/i),
          "#{code} summary leaked a backend path"
        expect(reason.hint).not_to match(/paid_code|--privileged/i),
          "#{code} hint leaked credentials or names"
      end
    end
  end

  describe ".build" do
    it "overrides fields from a template" do
      reason = described_class.build(
        :docker_memory_exhausted,
        hint: "Try a smaller workload."
      )

      expect(reason.code).to eq("docker_memory_exhausted")
      expect(reason.summary).to eq(described_class[:docker_memory_exhausted].summary)
      expect(reason.hint).to eq("Try a smaller workload.")
    end

    it "returns plain hashes that the UI can render safely" do
      payload = described_class[:unrelated_workload].to_h

      expect(payload).to include(:code, :summary, :hint)
      expect(payload.keys).to all(be_a(Symbol))
    end
  end
end
