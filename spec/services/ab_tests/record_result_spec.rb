# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbTests::RecordResult do
  let(:prompt) { create(:prompt, :global, :with_version) }
  let(:ab_test) { create(:ab_test, prompt: prompt, status: "running", started_at: Time.current, min_samples_per_variant: 2) }
  let(:control) { create(:ab_test_variant, ab_test: ab_test, prompt_version: prompt.current_version, is_control: true) }
  let(:variant) { create(:ab_test_variant, ab_test: ab_test) }

  before do
    control
    variant
  end

  describe ".call" do
    it "records quality score on the assignment" do
      agent_run = create(:agent_run)
      assignment = create(:ab_test_assignment, ab_test: ab_test, ab_test_variant: variant, agent_run: agent_run)

      described_class.call(ab_test: ab_test, agent_run: agent_run, quality_score: 0.85)

      expect(assignment.reload.quality_score.to_f).to eq(0.85)
    end

    it "updates variant aggregate scores" do
      agent_run = create(:agent_run)
      create(:ab_test_assignment, ab_test: ab_test, ab_test_variant: variant, agent_run: agent_run)

      described_class.call(ab_test: ab_test, agent_run: agent_run, quality_score: 0.8)

      expect(variant.reload.sample_count).to eq(1)
      expect(variant.avg_quality_score.to_f).to eq(0.8)
    end

    it "does nothing when agent_run has no assignment" do
      agent_run = create(:agent_run)
      expect { described_class.call(ab_test: ab_test, agent_run: agent_run, quality_score: 0.5) }.not_to raise_error
    end

    it "raises for invalid quality_score" do
      agent_run = create(:agent_run)
      create(:ab_test_assignment, ab_test: ab_test, ab_test_variant: variant, agent_run: agent_run)

      expect { described_class.call(ab_test: ab_test, agent_run: agent_run, quality_score: nil) }
        .to raise_error(ArgumentError, /quality_score must be a number/)
      expect { described_class.call(ab_test: ab_test, agent_run: agent_run, quality_score: "bad") }
        .to raise_error(ArgumentError, /quality_score must be a number/)
      expect { described_class.call(ab_test: ab_test, agent_run: agent_run, quality_score: 1.5) }
        .to raise_error(ArgumentError, /quality_score must be a number/)
    end
  end
end
