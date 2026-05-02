# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::CreateFollowup do
  describe ".call" do
    let(:project) { create(:project) }
    let(:issue) { create(:issue, project: project) }
    let(:provider) { create(:provider, user: project.created_by) }
    let(:analysis_run) do
      create(:agent_run, :analyze_issue_goal, :completed,
        project: project,
        issue: issue,
        provider: provider)
    end

    context "when goal is create_pr" do
      it "creates a queued create_pr run" do
        followup = described_class.call(agent_run: analysis_run, goal: "create_pr")

        expect(followup).to be_persisted
        expect(followup.goal).to eq("create_pr")
        expect(followup.status).to eq("queued")
      end

      it "inherits project and issue from the analysis run" do
        followup = described_class.call(agent_run: analysis_run, goal: "create_pr")

        expect(followup.project).to eq(project)
        expect(followup.issue).to eq(issue)
      end

      it "inherits provider from the analysis run" do
        followup = described_class.call(agent_run: analysis_run, goal: "create_pr")

        expect(followup.provider).to eq(provider)
      end

      it "sets trigger_type to automatic and auto_pick to true" do
        followup = described_class.call(agent_run: analysis_run, goal: "create_pr")

        expect(followup.trigger_type).to eq("automatic")
        expect(followup.auto_pick).to be true
      end
    end

    context "when goal is enhance_issue" do
      it "creates a queued enhance_issue run" do
        followup = described_class.call(agent_run: analysis_run, goal: "enhance_issue")

        expect(followup).to be_persisted
        expect(followup.goal).to eq("enhance_issue")
        expect(followup.status).to eq("queued")
      end
    end

    context "when analysis run has no issue" do
      it "raises ArgumentError" do
        analysis_run.issue = nil

        expect {
          described_class.call(agent_run: analysis_run, goal: "create_pr")
        }.to raise_error(ArgumentError, /must have an associated issue/)
      end
    end

    context "when goal is invalid" do
      it "raises ArgumentError" do
        expect {
          described_class.call(agent_run: analysis_run, goal: "invalid")
        }.to raise_error(ArgumentError, /Goal must be one of/)
      end
    end

    context "when analysis run has no provider" do
      let(:analysis_run) do
        create(:agent_run, :analyze_issue_goal, :completed,
          project: project,
          issue: issue,
          provider: nil)
      end

      it "resolves a provider via ProviderResolver" do
        resolved_provider = create(:provider, user: project.created_by)
        allow(AgentRuns::ProviderResolver).to receive(:call)
          .and_return([ resolved_provider.id, "claude_code" ])

        followup = described_class.call(agent_run: analysis_run, goal: "create_pr")

        expect(followup.provider).to eq(resolved_provider)
      end

      it "falls back to the first enabled agent type when the resolver returns no provider id" do
        allow(ProviderSupport).to receive(:container_executable_provider_keys).and_return(%w[codex])
        project.created_by.providers.update_all(enabled_for_agent_runs: false)
        allow(AgentRuns::ProviderResolver).to receive(:call)
          .and_return([ nil, "codex" ])

        followup = described_class.call(agent_run: analysis_run, goal: "create_pr")

        expect(followup.provider).to be_nil
        expect(followup.agent_type).to eq("codex")
      end
    end

    it "enqueues ProcessRunQueueJob" do
      expect {
        described_class.call(agent_run: analysis_run, goal: "create_pr")
      }.to have_enqueued_job(ProcessRunQueueJob)
    end

    context "when a duplicate active run exists" do
      let!(:existing_run) do
        create(:agent_run,
          project: project,
          issue: issue,
          goal: "create_pr",
          status: "queued")
      end

      it "returns the existing run instead of raising" do
        result = described_class.call(agent_run: analysis_run, goal: "create_pr")

        expect(result).to eq(existing_run)
      end
    end
  end
end
