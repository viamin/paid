# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTests::Analyze do
  let(:prompt) { create(:prompt, :global, :with_version) }
  let(:ab_test) { create(:ab_test, prompt: prompt, status: "running", started_at: Time.current, min_samples_per_variant: 5) }
  let!(:control) { create(:ab_test_variant, ab_test: ab_test, prompt_version: prompt.current_version, is_control: true) }
  let!(:variant) { create(:ab_test_variant, ab_test: ab_test) }

  def add_scores(test_variant, scores)
    scores.each do |score|
      run = create(:agent_run)
      create(:ab_test_assignment,
        ab_test: ab_test,
        ab_test_variant: test_variant,
        agent_run: run,
        quality_score: score)
    end
    test_variant.update!(sample_count: scores.size)
  end

  describe ".call" do
    it "returns insufficient_data when samples are below minimum" do
      add_scores(control, [ 0.5, 0.6 ])
      add_scores(variant, [ 0.7, 0.8 ])

      result = described_class.call(ab_test: ab_test)
      expect(result.status).to eq(:insufficient_data)
    end

    it "detects a significantly better variant" do
      # Control: low scores, Variant: high scores
      control_scores = [ 0.3, 0.35, 0.25, 0.3, 0.28, 0.32, 0.27, 0.31, 0.29, 0.33 ]
      variant_scores = [ 0.8, 0.85, 0.9, 0.82, 0.88, 0.84, 0.86, 0.83, 0.87, 0.81 ]

      add_scores(control, control_scores)
      add_scores(variant, variant_scores)

      result = described_class.call(ab_test: ab_test)
      expect(result.status).to eq(:winner_found)
      expect(result.winner).to eq(variant)
      expect(result.confidence).to be > 0.95
      expect(result.improvement).to be > 0.4
    end

    it "detects when control wins" do
      control_scores = [ 0.8, 0.85, 0.9, 0.82, 0.88, 0.84, 0.86, 0.83, 0.87, 0.81 ]
      variant_scores = [ 0.3, 0.35, 0.25, 0.3, 0.28, 0.32, 0.27, 0.31, 0.29, 0.33 ]

      add_scores(control, control_scores)
      add_scores(variant, variant_scores)

      result = described_class.call(ab_test: ab_test)
      expect(result.status).to eq(:control_wins)
    end

    it "reports no significant difference for similar scores" do
      control_scores = [ 0.5, 0.52, 0.48, 0.51, 0.49, 0.5, 0.51, 0.49, 0.5, 0.5 ]
      variant_scores = [ 0.51, 0.5, 0.49, 0.52, 0.5, 0.51, 0.5, 0.49, 0.51, 0.5 ]

      add_scores(control, control_scores)
      add_scores(variant, variant_scores)

      result = described_class.call(ab_test: ab_test)
      expect(result.status).to eq(:no_significant_difference)
    end

    it "handles the case with no control variant" do
      control.destroy!
      result = described_class.call(ab_test: ab_test)
      expect(result.status).to eq(:insufficient_data)
    end
  end

  describe "Welch's t-test implementation" do
    it "produces valid p-values" do
      # Known test case: two clearly different distributions
      result = AbTests::Statistics.welch_t_test([ 1, 2, 3, 4, 5 ], [ 6, 7, 8, 9, 10 ])
      expect(result[:p_value]).to be < 0.01
      expect(result[:t]).to be < 0 # group1 mean < group2 mean

      # Known test case: identical distributions
      result = AbTests::Statistics.welch_t_test([ 5, 5, 5, 5, 5 ], [ 5, 5, 5, 5, 5 ])
      expect(result[:p_value]).to eq(1.0) # no difference
    end

    it "handles zero variance with different means as significant" do
      result = AbTests::Statistics.welch_t_test([ 0.3, 0.3, 0.3, 0.3, 0.3 ], [ 0.8, 0.8, 0.8, 0.8, 0.8 ])
      expect(result[:p_value]).to eq(0.0)
      expect(result[:t]).to eq(-Float::INFINITY)
    end
  end
end
