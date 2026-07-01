# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::PromptEvolutionWorkflow do
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
    let(:prompt_id) { 1 }
    let(:project_id) { 2 }
    let(:input) { { prompt_id: prompt_id, project_id: project_id } }

    before do
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger)
    end

    it "accepts a single input parameter" do
      params = workflow.method(:execute).parameters
      expect(params).to eq([ [ :req, :input ] ])
    end

    context "when evolution candidates exist" do
      let(:candidates) do
        [ { prompt_version_id: 10, avg_score: 0.55, run_count: 10, reasons: [ "low quality" ] } ]
      end

      let(:mutations) do
        [
          { template: "improved {{title}}", strategy: "refinement",
            reasoning: "better structure", expected_improvement: "clarity" }
        ]
      end

      before do
        allow(workflow).to receive(:run_activity) do |activity_class, activity_input, **_opts|
          case activity_class.name
          when "Activities::SampleRunsActivity"
            {
              prompt_id: prompt_id,
              evolution_candidates: candidates,
              prompt_stats: { 10 => { avg_score: 0.55, run_count: 10 } },
              sample_outputs: { successes: [], failures: [ "low score" ] },
              quality_metrics: [ { composite_score: 0.55 } ],
              total_samples: 50
            }
          when "Activities::GenerateMutationsActivity"
            { prompt_id: prompt_id, mutations: mutations }
          when "Activities::CreateEvolutionVariantsActivity"
            { prompt_id: prompt_id, variant_version_ids: [ 100, 101 ], variant_count: 2 }
          when "Activities::CreateEvolutionAbTestActivity"
            { ab_test_id: 42, status: :created, generation: 1 }
          else
            {}
          end
        end
      end

      it "returns evolution_started with A/B test details" do
        result = workflow.execute(input)

        expect(result[:status]).to eq(:evolution_started)
        expect(result[:prompt_id]).to eq(prompt_id)
        expect(result[:ab_test_id]).to eq(42)
        expect(result[:variant_count]).to eq(2)
        expect(result[:generation]).to eq(1)
      end

      it "calls all four activities in sequence" do
        workflow.execute(input)

        expect(workflow).to have_received(:run_activity)
          .with(Activities::SampleRunsActivity,
            hash_including(prompt_id: prompt_id, project_id: project_id), timeout: 60)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::GenerateMutationsActivity,
            hash_including(prompt_id: prompt_id), timeout: described_class::MUTATION_TIMEOUT)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::CreateEvolutionVariantsActivity,
            hash_including(prompt_id: prompt_id, project_id: project_id, mutations: mutations), timeout: 30)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::CreateEvolutionAbTestActivity,
            hash_including(prompt_id: prompt_id, variant_version_ids: [ 100, 101 ]),
            timeout: described_class::AB_TEST_TIMEOUT)
      end

      it "passes configured parameters through" do
        custom_input = input.merge(sample_size: 100, sample_days: 30, mutation_count: 5)
        workflow.execute(custom_input)

        expect(workflow).to have_received(:run_activity)
          .with(Activities::SampleRunsActivity,
            hash_including(sample_size: 100, sample_days: 30), timeout: 60)
        expect(workflow).to have_received(:run_activity)
          .with(Activities::GenerateMutationsActivity,
            hash_including(mutation_count: 5), timeout: described_class::MUTATION_TIMEOUT)
      end
    end

    context "when no evolution candidates exist" do
      before do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::SampleRunsActivity"
            {
              prompt_id: prompt_id,
              evolution_candidates: [],
              prompt_stats: { 10 => { avg_score: 0.9 } },
              sample_outputs: {},
              quality_metrics: [],
              total_samples: 50
            }
          else
            {}
          end
        end
      end

      it "returns no_candidates status" do
        result = workflow.execute(input)

        expect(result[:status]).to eq(:no_candidates)
        expect(result[:prompt_id]).to eq(prompt_id)
      end

      it "does not call mutation or A/B test activities" do
        workflow.execute(input)

        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::GenerateMutationsActivity, anything, any_args)
        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::CreateEvolutionAbTestActivity, anything, any_args)
      end
    end

    context "when no mutations are generated" do
      before do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::SampleRunsActivity"
            {
              prompt_id: prompt_id,
              evolution_candidates: [ { prompt_version_id: 10, avg_score: 0.5 } ],
              prompt_stats: {},
              sample_outputs: {},
              quality_metrics: [],
              total_samples: 50
            }
          when "Activities::GenerateMutationsActivity"
            { prompt_id: prompt_id, mutations: [] }
          else
            {}
          end
        end
      end

      it "returns no_mutations status" do
        result = workflow.execute(input)

        expect(result[:status]).to eq(:no_mutations)
        expect(result[:prompt_id]).to eq(prompt_id)
      end

      it "does not create variants or A/B test" do
        workflow.execute(input)

        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::CreateEvolutionVariantsActivity, anything, any_args)
        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::CreateEvolutionAbTestActivity, anything, any_args)
      end
    end

    context "when an activity raises an error" do
      before do
        allow(workflow).to receive(:run_activity)
          .and_raise(Temporalio::Error::ApplicationError.new("LLM failed", type: "MutationFailed"))
      end

      it "re-raises the error" do
        expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError)
      end

      it "does not mark the recovery action failed on cancellation" do
        allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
          case activity_class.name
          when "Activities::SampleRunsActivity"
            raise Temporalio::Error::CanceledError, "workflow canceled"
          else
            raise "unexpected activity #{activity_class.name}"
          end
        end

        expect { workflow.execute(input.merge(recovery_action_id: 99)) }.to raise_error(Temporalio::Error::CanceledError)
        expect(workflow).not_to have_received(:run_activity)
          .with(Activities::MarkQualityRecoveryActionActivity, anything, any_args)
      end
    end
  end
end
