# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::Collect do
  describe ".call" do
    let(:agent_run) { create(:agent_run, :completed, iterations: 3) }

    it "creates a quality metric for the agent run" do
      expect { described_class.call(agent_run: agent_run) }.to change(QualityMetric, :count).by(1)
    end

    it "sets iteration score in scores hash" do
      metric = described_class.call(agent_run: agent_run)

      expect(metric.scores["iterations"]).to be_present
    end

    it "calculates a composite score" do
      metric = described_class.call(agent_run: agent_run)

      expect(metric.composite_score).to be_present
    end

    it "does not create duplicate metrics" do
      described_class.call(agent_run: agent_run)

      expect { described_class.call(agent_run: agent_run) }.not_to change(QualityMetric, :count)
    end

    context "with A/B test assignment" do
      let(:prompt) { create(:prompt, :with_version) }
      let(:ab_test) { create(:ab_test, prompt: prompt, status: "running", started_at: Time.current) }
      let!(:variant) { create(:ab_test_variant, ab_test: ab_test, is_control: true) }
      let!(:assignment) { create(:ab_test_assignment, ab_test: ab_test, ab_test_variant: variant, agent_run: agent_run) }

      it "sets quality_score on the assignment" do
        described_class.call(agent_run: agent_run)

        expect(assignment.reload.quality_score).to be_present
      end

      it "updates variant aggregate stats" do
        expect { described_class.call(agent_run: agent_run) }
          .to change { variant.reload.sample_count }.by(1)
      end

      it "adjusts variant aggregates on re-collection without changing sample_count" do
        described_class.call(agent_run: agent_run)

        expect { described_class.call(agent_run: agent_run) }
          .not_to change { variant.reload.sample_count }
      end
    end

    context "with prompt_version" do
      let(:prompt) { create(:prompt, :with_version) }
      let(:agent_run) { create(:agent_run, :completed, iterations: 3, prompt_version: prompt.current_version) }

      it "updates prompt version usage stats" do
        described_class.call(agent_run: agent_run)

        pv = prompt.current_version.reload
        expect(pv.usage_count).to eq(1)
        expect(pv.avg_quality_score).to be_present
      end
    end
  end
end
