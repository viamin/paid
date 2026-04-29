# frozen_string_literal: true

require "rails_helper"

RSpec.describe KnowledgeEvolutionJob do
  let(:job) { described_class.new }
  let(:temporal_client) { instance_double(Temporalio::Client) }

  before do
    allow(Paid).to receive(:temporal_client).and_return(temporal_client)
    allow(temporal_client).to receive(:start_workflow)
    allow(ProjectWorkflowManager).to receive(:start_polling)
    allow(EnqueueKnowledgeCollectionJob).to receive(:perform_later)
  end

  describe "#perform" do
    let(:account) { create(:account) }

    def create_enhance_runs(project, count:, completed_at: 1.day.ago)
      count.times do
        create(:agent_run, :completed,
          project: project,
          goal: "enhance_issue",
          completed_at: completed_at)
      end
    end

    context "with an eligible project" do
      let(:project) { create(:project, account: account, knowledge_evolution_enabled: true) }

      before { create_enhance_runs(project, count: 5) }

      it "starts a workflow for the eligible project" do
        job.perform

        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::KnowledgeEvolutionWorkflow,
          hash_including(project_id: project.id, lookback_days: 14),
          hash_including(id: "knowledge-evolution-#{project.id}-#{Date.current}")
        )
      end
    end

    context "with a project that has evolution disabled" do
      let(:project) { create(:project, account: account, knowledge_evolution_enabled: false) }

      before { create_enhance_runs(project, count: 10) }

      it "does not start a workflow" do
        job.perform

        expect(temporal_client).not_to have_received(:start_workflow)
      end
    end

    context "with a project that has insufficient runs" do
      let(:project) { create(:project, account: account, knowledge_evolution_enabled: true) }

      before { create_enhance_runs(project, count: 3) }

      it "does not start a workflow" do
        job.perform

        expect(temporal_client).not_to have_received(:start_workflow)
      end
    end

    context "with runs older than the lookback window" do
      let(:project) { create(:project, account: account, knowledge_evolution_enabled: true) }

      before { create_enhance_runs(project, count: 10, completed_at: 30.days.ago) }

      it "does not start a workflow" do
        job.perform

        expect(temporal_client).not_to have_received(:start_workflow)
      end
    end

    context "when scoped to a specific project" do
      let(:project_a) { create(:project, account: account, knowledge_evolution_enabled: true) }
      let(:project_b) { create(:project, account: account, knowledge_evolution_enabled: true) }

      before do
        create_enhance_runs(project_a, count: 5)
        create_enhance_runs(project_b, count: 5)
      end

      it "only starts a workflow for the specified project" do
        job.perform(project_id: project_a.id)

        expect(temporal_client).to have_received(:start_workflow).once
        expect(temporal_client).to have_received(:start_workflow).with(
          Workflows::KnowledgeEvolutionWorkflow,
          hash_including(project_id: project_a.id),
          anything
        )
      end
    end

    context "when workflow start raises an error" do
      let(:project) { create(:project, account: account, knowledge_evolution_enabled: true) }

      before do
        create_enhance_runs(project, count: 5)
        allow(temporal_client).to receive(:start_workflow).and_raise(StandardError, "connection lost")
      end

      it "logs a warning and does not raise" do
        expect(Rails.logger).to receive(:warn).with(
          hash_including(message: "knowledge_evolution.job_failed_for_project", project_id: project.id)
        )

        expect { job.perform }.not_to raise_error
      end
    end
  end
end
