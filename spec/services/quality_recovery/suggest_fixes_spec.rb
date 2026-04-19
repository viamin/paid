# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityRecovery::SuggestFixes do
  describe ".call" do
    let(:project) { create(:project) }

    context "with no patterns" do
      it "returns empty suggestions" do
        diagnosis = { patterns: [] }
        result = described_class.call(project: project, diagnosis: diagnosis)

        expect(result).to be_empty
      end
    end

    context "with prompt version regression" do
      let!(:prompt) { create(:prompt, project: project) }
      let!(:previous_version) { prompt.create_version!(template: "v1 template") }
      let!(:current_version) { prompt.create_version!(template: "v2 template") }

      it "suggests rolling back to the previous version" do
        diagnosis = {
          patterns: [ {
            type: "prompt_version_regression",
            severity: "critical",
            details: {
              prompt_version_id: current_version.id,
              failure_rate: 0.6,
              run_count: 5
            }
          } ]
        }

        result = described_class.call(project: project, diagnosis: diagnosis)

        rollback = result.find { |s| s[:action_type] == "prompt_rollback" }
        expect(rollback).to be_present
        expect(rollback[:parameters][:to_version_id]).to eq(previous_version.id)
      end

      it "includes resume_with_monitoring as final suggestion" do
        diagnosis = {
          patterns: [ {
            type: "prompt_version_regression",
            severity: "warning",
            details: {
              prompt_version_id: current_version.id,
              failure_rate: 0.4,
              run_count: 5
            }
          } ]
        }

        result = described_class.call(project: project, diagnosis: diagnosis)

        expect(result.last[:action_type]).to eq("resume_with_monitoring")
      end
    end

    context "with agent type failures" do
      it "suggests switching to a successful agent type" do
        create(:agent_run, :completed, project: project, agent_type: "cursor", completed_at: 1.day.ago)

        diagnosis = {
          patterns: [ {
            type: "agent_type_failures",
            severity: "warning",
            details: {
              agent_type: "claude_code",
              failure_rate: 0.5,
              run_count: 6,
              error_messages: [ "timeout" ]
            }
          } ]
        }

        result = described_class.call(project: project, diagnosis: diagnosis)

        model_change = result.find { |s| s[:action_type] == "model_change" }
        expect(model_change).to be_present
        expect(model_change[:parameters][:to_agent_type]).to eq("cursor")
      end
    end

    context "with quality score decline" do
      it "suggests configuration adjustment" do
        diagnosis = {
          patterns: [ {
            type: "quality_score_decline",
            severity: "warning",
            details: {
              recent_average: 0.45,
              older_average: 0.80,
              drop: 0.35
            }
          } ]
        }

        result = described_class.call(project: project, diagnosis: diagnosis)

        config_adj = result.find { |s| s[:action_type] == "config_adjustment" }
        expect(config_adj).to be_present
        expect(config_adj[:parameters][:adjustment_type]).to eq("review_settings")
      end
    end

    context "with high failure rate including timeouts" do
      it "suggests timeout increase" do
        diagnosis = {
          patterns: [ {
            type: "high_failure_rate",
            severity: "warning",
            details: {
              failure_count: 4,
              total_count: 10,
              failure_rate: 0.4,
              statuses: { "timeout" => 3, "failed" => 1 }
            }
          } ]
        }

        result = described_class.call(project: project, diagnosis: diagnosis)

        timeout_fix = result.find { |s| s[:parameters][:adjustment_type] == "timeout_increase" }
        expect(timeout_fix).to be_present
      end
    end

    context "with anomaly cluster" do
      it "suggests anomaly investigation" do
        diagnosis = {
          patterns: [ {
            type: "anomaly_cluster",
            severity: "warning",
            details: {
              metric_name: "tokens_total",
              anomaly_count: 4,
              critical_count: 1,
              avg_deviation: 3.5
            }
          } ]
        }

        result = described_class.call(project: project, diagnosis: diagnosis)

        investigation = result.find { |s| s[:parameters][:adjustment_type] == "anomaly_investigation" }
        expect(investigation).to be_present
        expect(investigation[:parameters][:metric_name]).to eq("tokens_total")
      end
    end
  end
end
