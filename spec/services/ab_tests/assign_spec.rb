# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTests::Assign do
  let(:prompt) { create(:prompt, :global, :with_version) }
  let(:ab_test) { create(:ab_test, prompt: prompt, status: "running", started_at: Time.current) }
  let!(:control) { create(:ab_test_variant, ab_test: ab_test, prompt_version: prompt.current_version, is_control: true) }
  let!(:variant) { create(:ab_test_variant, ab_test: ab_test) }

  describe ".call" do
    it "creates an assignment for the agent run" do
      agent_run = create(:agent_run)
      assignment = described_class.call(ab_test: ab_test, agent_run: agent_run)

      expect(assignment).to be_persisted
      expect(assignment.ab_test).to eq(ab_test)
      expect(assignment.agent_run).to eq(agent_run)
      expect([ control, variant ]).to include(assignment.ab_test_variant)
    end

    it "balances assignments across variants" do
      # Give control more samples to bias selection toward the variant
      control.update!(sample_count: 10)
      variant.update!(sample_count: 0)

      assignments = 20.times.map do
        run = create(:agent_run)
        described_class.call(ab_test: ab_test, agent_run: run)
      end

      variant_count = assignments.count { |a| a.ab_test_variant == variant }
      # With control at 10 and variant at 0, variant should get most assignments
      expect(variant_count).to be > 10
    end

    it "distributes evenly when all variants have equal samples" do
      control.update!(sample_count: 5)
      variant.update!(sample_count: 5)

      counts = Hash.new(0)
      100.times do
        run = create(:agent_run)
        assignment = described_class.call(ab_test: ab_test, agent_run: run)
        counts[assignment.ab_test_variant_id] += 1
      end

      # With equal samples, each should get roughly 50%
      expect(counts[control.id]).to be_between(30, 70)
      expect(counts[variant.id]).to be_between(30, 70)
    end
  end
end
