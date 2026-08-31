# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityMetrics::EvaluateGate do
  describe ".call" do
    let(:project) { create(:project) }
    let(:run) { create(:agent_run, project: project) }

    context "with no thresholds" do
      it "returns empty array" do
        metric = create(:quality_metric, agent_run: run, composite_score: 0.5)
        result = described_class.call(quality_metric: metric)
        expect(result).to eq([])
      end
    end

    context "with a min threshold" do
      let(:threshold) do
        create(:quality_threshold, :gate, project: project,
          metric_type: "composite_score", min_value: 0.6)
      end

      before { threshold }

      it "creates a trigger event when score breaches threshold" do
        metric = create(:quality_metric, agent_run: run, composite_score: 0.4)

        expect { described_class.call(quality_metric: metric) }
          .to change(QualityGateEvent, :count).by(1)

        event = QualityGateEvent.last
        expect(event.event_type).to eq("trigger")
        expect(event.score_value).to eq(0.4)
        expect(event.threshold_value).to eq(0.6)
      end

      it "does not create event when score is above threshold" do
        metric = create(:quality_metric, agent_run: run, composite_score: 0.8)

        expect { described_class.call(quality_metric: metric) }
          .not_to change(QualityGateEvent, :count)
      end

      it "creates recovery event when score returns above threshold" do
        metric1 = create(:quality_metric, agent_run: run, composite_score: 0.4)
        described_class.call(quality_metric: metric1)

        run2 = create(:agent_run, :with_custom_prompt, project: project)
        metric2 = create(:quality_metric, :human, agent_run: run2, composite_score: 0.8)

        expect { described_class.call(quality_metric: metric2) }
          .to change(QualityGateEvent, :count).by(1)

        event = QualityGateEvent.last
        expect(event.event_type).to eq("recovery")
      end

      it "does not duplicate trigger events" do
        metric1 = create(:quality_metric, agent_run: run, composite_score: 0.4)
        described_class.call(quality_metric: metric1)

        run2 = create(:agent_run, :with_custom_prompt, project: project)
        metric2 = create(:quality_metric, :human, agent_run: run2, composite_score: 0.3)

        expect { described_class.call(quality_metric: metric2) }
          .not_to change(QualityGateEvent, :count)
      end
    end

    context "with disabled threshold" do
      it "skips disabled thresholds" do
        create(:quality_threshold, :gate, :disabled, project: project,
          metric_type: "composite_score", min_value: 0.6)
        metric = create(:quality_metric, agent_run: run, composite_score: 0.4)

        expect { described_class.call(quality_metric: metric) }
          .not_to change(QualityGateEvent, :count)
      end
    end

    context "with individual score threshold" do
      let(:threshold) do
        create(:quality_threshold, :gate, project: project,
          metric_type: "ci_passed", min_value: 0.5)
      end

      before { threshold }

      it "evaluates individual score keys" do
        metric = create(:quality_metric, agent_run: run,
          composite_score: 0.9,
          scores: { "ci_passed" => 0.0, "pr_created" => 1.0 })

        expect { described_class.call(quality_metric: metric) }
          .to change(QualityGateEvent, :count).by(1)
      end
    end
  end
end
