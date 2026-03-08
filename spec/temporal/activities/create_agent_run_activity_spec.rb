# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::CreateAgentRunActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project) }

  before do
    # Stub conversation_section_for so the activity does not make real HTTP
    # calls to fetch issue comments (blocked by WebMock). Individual tests
    # that exercise conversation section behavior override this stub.
    allow(Prompts::BuildForIssue).to receive(:conversation_section_for).and_return("")
  end

  describe "#execute" do
    it "creates an agent run for the project and issue" do
      result = activity.execute(project_id: project.id, issue_id: issue.id)

      expect(result[:agent_run_id]).to be_present
      expect(result[:provider_attempt_count]).to eq(1)
      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.project).to eq(project)
      expect(agent_run.issue).to eq(issue)
      expect(agent_run.status).to eq("pending")
      expect(agent_run.agent_type).to eq("claude_code")
    end

    it "accepts a custom agent_type" do
      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "aider")

      agent_run = AgentRun.find(result[:agent_run_id])
      expect(agent_run.agent_type).to eq("aider")
      expect(result[:provider_attempt_count]).to eq(1)
    end

    it "returns deduplicated provider_attempt_count when fallback is enabled" do
      project.created_by.providers.find_or_create_by!(provider_key: "cursor")
      project.created_by.providers.find_or_create_by!(provider_key: "aider")
      project.created_by.settings.update!(fallback_enabled: true, fallback_providers: %w[claude cursor aider])

      result = activity.execute(project_id: project.id, issue_id: issue.id, agent_type: "claude_code")

      expect(result[:provider_attempt_count]).to eq(3)
    end

    it "updates the issue paid_state to in_progress" do
      activity.execute(project_id: project.id, issue_id: issue.id)

      expect(issue.reload.paid_state).to eq("in_progress")
    end

    it "raises ActiveRecord::RecordNotFound for invalid project_id" do
      expect {
        activity.execute(project_id: -1, issue_id: issue.id)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises ActiveRecord::RecordNotFound for invalid issue_id" do
      expect {
        activity.execute(project_id: project.id, issue_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    context "with prompt versioning" do
      let!(:prompt) do
        Prompt.find_by(slug: "coding.issue_implementation")&.destroy!
        p = create(:prompt, :global, slug: "coding.issue_implementation")
        p.create_version!(
          template: <<~'TEMPLATE'
            Work on {{title}} (#{{issue_number}})

            {{body}}

            Test: {{test_command}}
            Lint: {{lint_command}}
          TEMPLATE
        )
        p
      end

      it "resolves and renders prompt version when no custom_prompt is provided" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_version).to eq(prompt.current_version)
        expect(agent_run.custom_prompt).to include(issue.title)
        expect(agent_run.custom_prompt).to include(issue.github_number.to_s)
      end

      it "renders template with correct variables" do
        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.custom_prompt).to include("Test: bundle exec rspec")
        expect(agent_run.custom_prompt).to include("Lint: bundle exec rubocop")
      end

      it "does not assign prompt_version when custom_prompt is provided" do
        result = activity.execute(
          project_id: project.id,
          issue_id: issue.id,
          custom_prompt: "Do something custom"
        )

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_version).to be_nil
        expect(agent_run.custom_prompt).to eq("Do something custom")
      end

      it "does not assign prompt_version when no issue is present" do
        result = activity.execute(
          project_id: project.id,
          issue_id: nil,
          custom_prompt: "No issue prompt"
        )

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_version).to be_nil
        expect(agent_run.custom_prompt).to eq("No issue prompt")
      end

      it "handles nil when Prompts::Resolve returns nil" do
        prompt.update!(active: false)

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_version).to be_nil
        expect(agent_run.custom_prompt).to be_nil
      end

      it "does not use prompt version when issue is untrusted" do
        untrusted_issue = create(:issue, project: project, github_creator_login: "untrusted-user")

        result = activity.execute(project_id: project.id, issue_id: untrusted_issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.prompt_version).to be_nil
        expect(agent_run.custom_prompt).to be_nil
      end

      it "appends trusted issue comments to the rendered custom_prompt" do
        trusted_login = project.allowed_github_usernames.first
        comment = OpenStruct.new(
          user: OpenStruct.new(login: trusted_login),
          body: "Please also update the docs"
        )
        allow(Prompts::BuildForIssue).to receive(:conversation_section_for).and_return(
          Prompts::BuildForIssue.format_conversation_section([ comment ])
        )

        result = activity.execute(project_id: project.id, issue_id: issue.id)

        agent_run = AgentRun.find(result[:agent_run_id])
        expect(agent_run.custom_prompt).to include("Conversation Comments")
        expect(agent_run.custom_prompt).to include("Please also update the docs")
      end
    end

    context "with agent_run_id (resuming queued run)" do
      it "transitions a queued run to pending" do
        queued_run = create(:agent_run, :queued, project: project, issue: issue)

        result = activity.execute(agent_run_id: queued_run.id, project_id: project.id)

        expect(result[:agent_run_id]).to eq(queued_run.id)
        expect(queued_run.reload.status).to eq("pending")
      end

      it "updates issue paid_state to in_progress" do
        queued_run = create(:agent_run, :queued, project: project, issue: issue)

        activity.execute(agent_run_id: queued_run.id, project_id: project.id)

        expect(issue.reload.paid_state).to eq("in_progress")
      end

      it "does not change status if run is already pending" do
        pending_run = create(:agent_run, project: project, issue: issue, status: "pending")

        result = activity.execute(agent_run_id: pending_run.id, project_id: project.id)

        expect(result[:agent_run_id]).to eq(pending_run.id)
        expect(pending_run.reload.status).to eq("pending")
      end
    end
  end
end
