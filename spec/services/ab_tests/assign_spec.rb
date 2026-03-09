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

    it "selects under-assigned variant when rand falls in its weight range" do
      # Control has 10 assignments, variant has 0.
      # DB order: [control, variant]. Weights: [1, 11]. Total: 12.
      # control range: 0..1/12 (~0.083), variant range: 1/12..1 (~0.083..1)
      # rand=0.5 falls in the variant range.
      10.times do
        create(:ab_test_assignment, ab_test: ab_test, ab_test_variant: control, agent_run: create(:agent_run))
      end

      assigner = described_class.new(ab_test: ab_test, agent_run: create(:agent_run))
      allow(assigner).to receive(:rand).and_return(0.5)
      selected = assigner.send(:select_variant)

      expect(selected).to eq(variant)
    end

    it "selects over-assigned variant's complement when rand is very low" do
      # Control has 10 assignments, variant has 0.
      # DB order: [control, variant]. Weights: [1, 11]. Total: 12.
      # control range: 0..1/12 (~0.083).
      # rand=0.01 falls in the control range despite control being over-assigned.
      10.times do
        create(:ab_test_assignment, ab_test: ab_test, ab_test_variant: control, agent_run: create(:agent_run))
      end

      assigner = described_class.new(ab_test: ab_test, agent_run: create(:agent_run))
      allow(assigner).to receive(:rand).and_return(0.01)
      selected = assigner.send(:select_variant)

      expect(selected).to eq(control)
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
