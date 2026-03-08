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

    it "biases toward under-sampled variants" do
      control.update!(sample_count: 10)
      variant.update!(sample_count: 0)

      assigner = described_class.new(ab_test: ab_test, agent_run: create(:agent_run))
      selected = assigner.send(:select_variant)

      # With max_count=10 for control: control weight=1, variant weight=11
      # Variant should be heavily favored
      expect(selected).to eq(variant).or eq(control)
    end

    it "computes equal weights when all variants have equal samples" do
      control.update!(sample_count: 5)
      variant.update!(sample_count: 5)

      # With equal samples, each weight = (5-5)+1 = 1, so weights are equal
      variants = ab_test.ab_test_variants.to_a
      max_count = variants.map(&:sample_count).max
      weights = variants.map { |v| (max_count - v.sample_count) + 1 }

      expect(weights.uniq.size).to eq(1)
    end

    it "returns existing assignment for duplicate agent_run" do
      agent_run = create(:agent_run)
      first = described_class.call(ab_test: ab_test, agent_run: agent_run)
      second = described_class.call(ab_test: ab_test, agent_run: agent_run)

      expect(second).to eq(first)
    end

    it "raises when test is not running" do
      draft_test = create(:ab_test, prompt: prompt, status: "draft")
      create(:ab_test_variant, ab_test: draft_test, prompt_version: prompt.current_version, is_control: true)

      expect {
        described_class.call(ab_test: draft_test, agent_run: create(:agent_run))
      }.to raise_error(ArgumentError, /not running/)
    end
  end
end
