# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTests::Assign do
  describe ".call" do
    let(:prompt) { create(:prompt, :global, :with_version) }

    it "assigns a variant when a running test exists" do
      test = create(:ab_test, prompt: prompt, status: "running", started_at: Time.current)
      create(:ab_test_variant, ab_test: test, is_control: true)
      create(:ab_test_variant, ab_test: test)
      agent_run = create(:agent_run)

      assignment = described_class.call(ab_test: test, agent_run: agent_run)

      expect(assignment).to be_an(AbTestAssignment)
      expect(test.ab_test_variants).to include(assignment.ab_test_variant)
    end

    it "prevents double-assignment for the same agent run" do
      test = create(:ab_test, prompt: prompt, status: "running", started_at: Time.current)
      create(:ab_test_variant, ab_test: test, is_control: true)
      create(:ab_test_variant, ab_test: test)
      agent_run = create(:agent_run)

      first_result = described_class.call(ab_test: test, agent_run: agent_run)
      second_result = described_class.call(ab_test: test, agent_run: agent_run)

      expect(first_result.ab_test_variant).to eq(second_result.ab_test_variant)
    end

    it "raises when the test is not running" do
      test = create(:ab_test, prompt: prompt, status: "draft")
      create(:ab_test_variant, ab_test: test, is_control: true)
      agent_run = create(:agent_run)

      expect { described_class.call(ab_test: test, agent_run: agent_run) }
        .to raise_error(ArgumentError, /not running/)
    end
  end
end
