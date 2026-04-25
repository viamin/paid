# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateEvolutionAbTestActivity do
  let(:activity) { described_class.new }

  describe "class" do
    it "inherits from BaseActivity" do
      expect(described_class.superclass).to eq(Activities::BaseActivity)
    end
  end

  describe "#execute" do
    let(:prompt) { create(:prompt, :global, :with_version) }
    let!(:variant_version) do
      prompt.create_pending_version!(
        template: "Evolved prompt for {{title}}",
        created_by: "evolution"
      )
    end

    let(:input) do
      {
        prompt_id: prompt.id,
        variant_version_ids: [ variant_version.id ],
        min_samples_per_variant: 20,
        confidence_threshold: 0.90
      }
    end

    it "creates and starts an A/B test" do
      result = activity.execute(input)

      expect(result[:ab_test_id]).to be_present
      expect(result[:status]).to eq(:created)
      expect(result[:generation]).to eq(1)

      ab_test = AbTest.find(result[:ab_test_id])
      expect(ab_test.status).to eq("running")
      expect(ab_test.prompt).to eq(prompt)
      expect(ab_test.min_samples_per_variant).to eq(20)
      expect(ab_test.confidence_threshold).to eq(0.90)
    end

    it "creates control and variant entries" do
      result = activity.execute(input)

      ab_test = AbTest.find(result[:ab_test_id])
      expect(ab_test.ab_test_variants.count).to eq(2)
      expect(ab_test.control_variant).to be_present
      expect(ab_test.non_control_variants.count).to eq(1)
    end

    it "tracks the A/B test without marking recovery executed before an outcome" do
      recovery_action = create(:quality_recovery_action, :prompt_evolution, :executing, executed_at: nil)

      result = activity.execute(input.merge(recovery_action_id: recovery_action.id))

      ab_test = AbTest.find(result[:ab_test_id])
      recovery_action.reload
      expect(recovery_action.status).to eq("executing")
      expect(recovery_action.executed_at).to be_nil
      expect(recovery_action.result).to include(
        "status" => "created",
        "ab_test_id" => ab_test.id,
        "prompt_id" => prompt.id
      )
    end

    context "when a running test already exists" do
      let!(:existing_test) do
        test = create(:ab_test, prompt: prompt, status: "draft")
        test.ab_test_variants.create!(prompt_version: prompt.current_version, is_control: true)
        test.ab_test_variants.create!(prompt_version: variant_version, is_control: false)
        test.start!
        test
      end

      it "returns already_running status without creating a new test" do
        result = activity.execute(input)

        expect(result[:status]).to eq(:already_running)
        expect(result[:ab_test_id]).to eq(existing_test.id)
      end
    end

    context "with generation counting" do
      before do
        # Create a prior completed evolution test
        test = create(:ab_test, prompt: prompt, name: "Evolution gen-1 2026-01-01")
        test.ab_test_variants.create!(prompt_version: prompt.current_version, is_control: true)
        test.ab_test_variants.create!(prompt_version: variant_version, is_control: false)
      end

      it "increments the generation number" do
        result = activity.execute(input)

        expect(result[:generation]).to eq(2)
      end
    end
  end
end
