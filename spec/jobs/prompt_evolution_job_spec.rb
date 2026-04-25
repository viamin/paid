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

    def create_completed_runs(count, prompt_version:, project:, composite_score: 0.5, goal: "create_pr")
      count.times do
        run = create(:agent_run, :completed,
          project: project,
          prompt_version: prompt_version,
          goal: goal,
          completed_at: 1.day.ago)
        create(:quality_metric, :automated, agent_run: run,
          prompt_version: prompt_version, composite_score: composite_score)
      end
    end

    def create_failed_run(prompt_version:, project:, composite_score: 0.2, goal: "create_pr", error_message: "Agent produced low-quality output")
      run = create(:agent_run, :failed,
        project: project,
        prompt_version: prompt_version,
        goal: goal,
        completed_at: 1.day.ago,
        error_message: error_message)
      create(:quality_metric, :automated, agent_run: run,
        prompt_version: prompt_version, composite_score: composite_score)
    end

    def perform_targeted_quality_pause_job(project)
      job.perform(
        project_id: project.id,
        failure_only: true,
        metric_type: "composite_score",
        threshold: 0.5,
        goal_type: "create_pr",
        source: "quality_pause"
      )
    end

    def expect_targeted_workflow_for(prompt, project)
      expect(temporal_client).to have_received(:start_workflow).with(
        Workflows::PromptEvolutionWorkflow,
        hash_including(
          prompt_id: prompt.id,
          project_id: project.id,
          failure_only: true,
          metric_type: "composite_score",
          threshold: 0.5,
          goal_type: "create_pr",
          min_runs_for_evaluation: QualityThreshold::DEFAULT_MIN_SAMPLE_SIZE
        ),
        hash_including(id: "prompt-evolution-quality-pause-#{project.id}-#{prompt.id}-create_pr-composite_score-#{Date.current}")
      )
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
    end

    context "with targeted quality-pause evolution" do
      let(:other_project) { create(:project, account: account) }
      let(:healthy_prompt) { create(:prompt, :global, :with_version) }
      let(:workflow_calls) { [] }

      before do
        allow(temporal_client).to receive(:start_workflow) do |*args|
          workflow_calls << args
        end

        min_runs = PromptEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION
        create_completed_runs(min_runs, prompt_version: prompt_version, project: project, composite_score: 0.2)
        create_completed_runs(min_runs, prompt_version: healthy_prompt.current_version, project: project, composite_score: 0.9)
        create_completed_runs(min_runs, prompt_version: healthy_prompt.current_version, project: other_project, composite_score: 0.1)
      end

      it "starts workflows only for prompts used by low-quality runs in the paused project" do
        perform_targeted_quality_pause_job(project)

        prompt_evolution_calls = workflow_calls.select { |call| call.first == Workflows::PromptEvolutionWorkflow }
        expect(prompt_evolution_calls.map { |call| call.second[:prompt_id] }).to contain_exactly(prompt.id)
        expect_targeted_workflow_for(prompt, project)
      end

      it "starts workflows for prompts used by scoreable failed runs" do
        failed_prompt = create(:prompt, :global, :with_version)
        min_runs = PromptEvolution::SampleRuns::MIN_RUNS_FOR_EVALUATION
        (min_runs - 1).times { create_failed_run(prompt_version: failed_prompt.current_version, project: project) }
        create_completed_runs(1, prompt_version: failed_prompt.current_version, project: project, composite_score: 0.2)

        perform_targeted_quality_pause_job(project)

        prompt_evolution_calls = workflow_calls.select { |call| call.first == Workflows::PromptEvolutionWorkflow }
        expect(prompt_evolution_calls.map { |call| call.second[:prompt_id] }).to contain_exactly(prompt.id, failed_prompt.id)
        expect_targeted_workflow_for(failed_prompt, project)
      end

      it "skips targeted prompts with insufficient failing runs" do
        sparse_prompt = create(:prompt, :global, :with_version)
        create_failed_run(prompt_version: sparse_prompt.current_version, project: project)

        perform_targeted_quality_pause_job(project)

        prompt_evolution_calls = workflow_calls.select { |call| call.first == Workflows::PromptEvolutionWorkflow }
        expect(prompt_evolution_calls.map { |call| call.second[:prompt_id] }).not_to include(sparse_prompt.id)
      end

      it "ignores operational failed runs that are not quality scoreable" do
        failed_prompt = create(:prompt, :global, :with_version)
        create_failed_run(
          prompt_version: failed_prompt.current_version,
          project: project,
          error_message: "Docker exec failed"
        )

        perform_targeted_quality_pause_job(project)

        prompt_evolution_calls = workflow_calls.select { |call| call.first == Workflows::PromptEvolutionWorkflow }
        expect(prompt_evolution_calls.map { |call| call.second[:prompt_id] }).not_to include(failed_prompt.id)
      end

      it "ignores targeted failures outside the sample window" do
        old_prompt = create(:prompt, :global, :with_version)
        run = create(:agent_run, :completed,
          project: project,
          prompt_version: old_prompt.current_version,
          goal: "create_pr",
          completed_at: (described_class::SAMPLE_DAYS + 1).days.ago)
        create(:quality_metric, :automated, agent_run: run,
          prompt_version: old_prompt.current_version, composite_score: 0.2)

        perform_targeted_quality_pause_job(project)

        prompt_evolution_calls = workflow_calls.select { |call| call.first == Workflows::PromptEvolutionWorkflow }
        expect(prompt_evolution_calls.map { |call| call.second[:prompt_id] }).not_to include(old_prompt.id)
      end
    end
  end
end
