# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::KnowledgeEvolutionWorkflow do
  let(:workflow) { described_class.new }

  describe "class" do
    it "inherits from BaseWorkflow" do
      expect(described_class.superclass).to eq(Workflows::BaseWorkflow)
    end

    it "is a Temporal workflow definition" do
      expect(described_class).to be < Temporalio::Workflow::Definition
    end
  end

  describe "#execute" do
    let(:project_id) { 1 }
    let(:input) { { project_id: project_id } }

    before do
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger)
    end

    context "when enhance_issue data exists and gaps are found" do
      let(:sampled_runs) do
        [ { agent_run_id: 10, issue_title: "Add auth", questions_asked: [ "How does auth work?" ] } ]
      end

      let(:recommendations) do
        [ { recommendation_type: "add_collector", collector_type: "database_schema",
           priority: "high", description: "Collects DB schemas" } ]
      end

      before do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::SampleEnhanceRunsActivity"
            { runs: sampled_runs, artifact_usage: { "route" => { total_runs: 50, success_rate: 80.0 } } }
          when "Activities::AnalyzeKnowledgeGapsActivity"
            { project_id: project_id, recommendations: recommendations }
          when "Activities::RecordKnowledgeRecommendationsActivity"
            { project_id: project_id, created_count: 1, dismissed_count: 0 }
          else
            {}
          end
        end
      end

      it "returns completed with recommendation counts" do
        result = workflow.execute(input)

        expect(result[:status]).to eq(:completed)
        expect(result[:project_id]).to eq(project_id)
        expect(result[:recommendations_created]).to eq(1)
        expect(result[:recommendations_dismissed]).to eq(0)
      end

      it "calls all three activities in sequence" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(Activities::SampleEnhanceRunsActivity,
            hash_including(project_id: project_id), timeout: described_class::SAMPLE_TIMEOUT)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::AnalyzeKnowledgeGapsActivity,
            hash_including(project_id: project_id, sampled_runs: sampled_runs), timeout: described_class::ANALYSIS_TIMEOUT)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::RecordKnowledgeRecommendationsActivity,
            hash_including(project_id: project_id, recommendations: recommendations), timeout: described_class::RECORD_TIMEOUT)
      end
    end

    context "when no enhance_issue runs exist" do
      before do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::SampleEnhanceRunsActivity"
            { runs: [], artifact_usage: {} }
          else
            {}
          end
        end
      end

      it "returns no_data status" do
        result = workflow.execute(input)

        expect(result[:status]).to eq(:no_data)
        expect(result[:project_id]).to eq(project_id)
      end

      it "does not call analysis or record activities" do
        workflow.execute(input)

        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::AnalyzeKnowledgeGapsActivity, anything, any_args)
        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::RecordKnowledgeRecommendationsActivity, anything, any_args)
      end
    end

    context "when no knowledge gaps are found" do
      before do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::SampleEnhanceRunsActivity"
            { runs: [ { agent_run_id: 1 } ], artifact_usage: {} }
          when "Activities::AnalyzeKnowledgeGapsActivity"
            { project_id: project_id, recommendations: [] }
          else
            {}
          end
        end
      end

      it "returns no_gaps status" do
        result = workflow.execute(input)

        expect(result[:status]).to eq(:no_gaps)
        expect(result[:project_id]).to eq(project_id)
      end

      it "does not call the record activity" do
        workflow.execute(input)

        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::RecordKnowledgeRecommendationsActivity, anything, any_args)
      end
    end

    context "when an activity raises an error" do
      before do
        allow(workflow).to receive(:run_activity)
          .and_raise(Temporalio::Error::ApplicationError.new("LLM failed", type: "AnalysisFailed"))
      end

      it "re-raises the error" do
        expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError)
      end
    end
  end
end
