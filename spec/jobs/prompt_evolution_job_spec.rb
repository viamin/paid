# frozen_string_literal: true

require "rails_helper"

RSpec.describe PromptEvolutionJob do
  let(:job) { described_class.new }
  let(:temporal_client) { instance_double(Temporalio::Client) }

  before do
    allow(Paid).to receive(:temporal_client).and_return(temporal_client)
    allow(temporal_client).to receive(:start_workflow)
  end

  describe "#perform" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }
    let(:prompt) { create(:prompt, :global, :with_version) }
    let(:prompt_version) { prompt.current_version }

    def create_completed_runs(count, prompt_version:, project:)
      count.times do
        run = create(:agent_run, :completed,
          project: project,
          prompt_version: prompt_version,
          goal: "create_pr",
          completed_at: 1.day.ago)
        create(:quality_metric, :automated, agent_run: run,
          prompt_version: prompt_version, composite_score: 0.5)
      end
    end

    context "with an eligible prompt" do
      before do
        create_completed_runs(
          PromptEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION,
          prompt_version: prompt_version,
          project: project
        )
      end

      it "starts a Temporal workflow" do
        job.perform

        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::PromptEvolutionWorkflow,
          hash_including(prompt_id: prompt.id),
          hash_including(id: "prompt-evolution-#{prompt.id}-#{Date.current}")
        )
      end
    end

    context "with a targeted recovery prompt" do
      before do
        create_completed_runs(
          PromptEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION,
          prompt_version: prompt_version,
          project: project
        )
      end

      it "starts a scoped Temporal workflow with the recovery action id" do
        job.perform(project_id: project.id, prompt_id: prompt.id, recovery_action_id: 123)

        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::PromptEvolutionWorkflow,
          hash_including(prompt_id: prompt.id, project_id: project.id, recovery_action_id: 123),
          hash_including(id: "quality-recovery-prompt-evolution-123")
        )
      end
    end

    context "with a prompt that has a running A/B test" do
      before do
        create_completed_runs(
          PromptEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION,
          prompt_version: prompt_version,
          project: project
        )

        variant = prompt.create_pending_version!(
          template: "variant {{title}}",
          created_by: "evolution"
        )
        test = create(:ab_test, prompt: prompt, status: "draft")
        test.ab_test_variants.create!(prompt_version: prompt.current_version, is_control: true)
        test.ab_test_variants.create!(prompt_version: variant, is_control: false)
        test.start!
      end

      it "skips the prompt" do
        job.perform

        expect(temporal_client).not_to have_received(:start_workflow)
          .with(Workflows::PromptEvolutionWorkflow,
            hash_including(prompt_id: prompt.id), anything)
      end
    end

    context "with an inactive prompt" do
      before do
        prompt.update!(active: false)
        create_completed_runs(
          PromptEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION,
          prompt_version: prompt_version,
          project: project
        )
      end

      it "skips the prompt" do
        job.perform

        expect(temporal_client).not_to have_received(:start_workflow)
          .with(Workflows::PromptEvolutionWorkflow,
            hash_including(prompt_id: prompt.id), anything)
      end
    end

    context "with insufficient completed runs" do
      before do
        create_completed_runs(1, prompt_version: prompt_version, project: project)
      end

      it "skips the prompt" do
        job.perform

        expect(temporal_client).not_to have_received(:start_workflow)
          .with(Workflows::PromptEvolutionWorkflow,
            hash_including(prompt_id: prompt.id), anything)
      end

      it "marks targeted recovery failed when no workflow can start" do
        action = create(:quality_recovery_action, :prompt_evolution, :executing, executed_at: nil)

        job.perform(project_id: project.id, prompt_id: prompt.id, recovery_action_id: action.id)

        expect(action.reload.status).to eq("failed")
        expect(action.result["error"]).to include("status" => "no_eligible_prompt")
      end
    end

    context "with a targeted recovery prompt that already has a running A/B test" do
      let!(:running_test) do
        variant = prompt.create_pending_version!(
          template: "variant {{title}}",
          created_by: "evolution"
        )
        test = create(:ab_test, prompt: prompt, status: "draft")
        test.ab_test_variants.create!(prompt_version: prompt.current_version, is_control: true)
        test.ab_test_variants.create!(prompt_version: variant, is_control: false)
        test.start!
        test
      end

      it "tracks the running test instead of failing the recovery action" do
        action = create(:quality_recovery_action, :prompt_evolution, :executing, executed_at: nil)

        job.perform(project_id: project.id, prompt_id: prompt.id, recovery_action_id: action.id)

        action.reload
        expect(action.status).to eq("executing")
        expect(action.executed_at).to be_nil
        expect(action.result).to include(
          "status" => "already_running",
          "ab_test_id" => running_test.id,
          "prompt_id" => prompt.id
        )
      end
    end

    context "when workflow start fails for one prompt" do
      let(:prompt2) { create(:prompt, :global, :with_version) }

      before do
        create_completed_runs(
          PromptEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION,
          prompt_version: prompt_version,
          project: project
        )
        create_completed_runs(
          PromptEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION,
          prompt_version: prompt2.current_version,
          project: project
        )

        call_count = 0
        allow(temporal_client).to receive(:start_workflow) do
          call_count += 1
          raise "Temporal unavailable" if call_count == 1
        end
      end

      it "continues processing remaining prompts" do
        job.perform

        expect(temporal_client).to have_received(:start_workflow)
          .with(Workflows::PromptEvolutionWorkflow,
            hash_including(prompt_id: prompt.id), anything)
        expect(temporal_client).to have_received(:start_workflow)
          .with(Workflows::PromptEvolutionWorkflow,
            hash_including(prompt_id: prompt2.id), anything)
      end

      it "marks targeted recovery as workflow_start_failed when the eligible prompt fails" do
        action = create(:quality_recovery_action, :prompt_evolution, :executing, executed_at: nil)

        allow(temporal_client).to receive(:start_workflow).and_raise("Temporal unavailable")

        job.perform(project_id: project.id, prompt_id: prompt.id, recovery_action_id: action.id)

        expect(action.reload.status).to eq("failed")
        expect(action.result["error"]).to include("status" => "workflow_start_failed")
      end
    end
  end
end
