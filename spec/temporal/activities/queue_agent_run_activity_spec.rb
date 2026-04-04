# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::QueueAgentRunActivity do
  include ActiveJob::TestHelper

  let(:activity) { described_class.new }
  let(:user) { create(:user) }
  let(:project) { create(:project, account: user.account, created_by: user) }
  let(:issue) { create(:issue, project: project) }

  describe "#execute" do
    around do |example|
      original_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      clear_enqueued_jobs
      clear_performed_jobs
      example.run
    ensure
      clear_enqueued_jobs
      clear_performed_jobs
      ActiveJob::Base.queue_adapter = original_adapter
    end

    it "creates an agent run with queued status" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:agent_run_id]).to be_present
      expect(result[:queued]).to be true
      expect(ProcessRunQueueJob).to have_been_enqueued

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.status).to eq("queued")
      expect(agent_run.project).to eq(project)
      expect(agent_run.issue).to eq(issue)
      expect(agent_run.agent_type).to eq("claude_code")
      expect(agent_run.provider).to eq(user.providers.find_by!(provider_key: "claude"))
    end

    it "accepts a custom agent_type" do
      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "aider")

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.agent_type).to eq("aider")
      expect(agent_run.provider_id).to be_nil
    end

    it "derives agent_type from provider_id when only a provider is supplied" do
      codex_provider = user.providers.find_or_create_by!(provider_key: "codex", auth_type: "subscription")

      result = activity.execute(project_id: project.id, issue_id: issue.id, provider_id: codex_provider.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.provider).to eq(codex_provider)
      expect(agent_run.agent_type).to eq("codex")
    end

    it "uses the configured primary provider when agent type is omitted" do
      codex_provider = user.providers.find_or_create_by!(provider_key: "codex", auth_type: "subscription")
      user.settings.update!(default_agent_provider: codex_provider.routing_key)

      result = activity.execute(project_id: project.id, issue_id: issue.id)

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.provider).to eq(codex_provider)
      expect(agent_run.agent_type).to eq("codex")
    end

    it "stores custom_prompt and source_pull_request_number" do
      result = activity.execute(
        project_id: project.id,
        issue_id: issue.id,
        custom_prompt: "Fix the bug",
        source_pull_request_number: 42
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.custom_prompt).to eq("Fix the bug")
      expect(agent_run.source_pull_request_number).to eq(42)
    end

    it "works without an issue" do
      result = activity.execute(
        project_id: project.id,
        custom_prompt: "Do something"
      )

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.issue).to be_nil
      expect(agent_run.custom_prompt).to eq("Do something")
    end

    context "when a duplicate run exists" do
      it "returns existing run when a queued run exists for the same issue" do
        existing = create(:agent_run, :queued, project: project, issue: issue)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
        expect(AgentRun.where(project: project, issue: issue).count).to eq(1)
        expect(ProcessRunQueueJob).not_to have_been_enqueued
      end

      it "returns existing run when an active run exists for the same issue" do
        existing = create(:agent_run, :running, project: project, issue: issue)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
        expect(ProcessRunQueueJob).not_to have_been_enqueued
      end

      it "returns existing run when a queued run exists for the same PR" do
        existing = create(:agent_run, :queued, project: project,
          source_pull_request_number: 42, custom_prompt: "Fix it")

        result = activity.execute(
          project_id: project.id,
          source_pull_request_number: 42,
          custom_prompt: "Fix it again"
        )

        expect(result[:agent_run_id]).to eq(existing.id)
        expect(result[:duplicate]).to be true
        expect(ProcessRunQueueJob).not_to have_been_enqueued
      end

      it "allows queueing when no active/queued run exists for the issue" do
        create(:agent_run, :completed, project: project, issue: issue)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        expect(result[:queued]).to be true
        expect(result[:duplicate]).to be_nil
      end
    end
  end
end
