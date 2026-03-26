# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateGithubIssueActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, :with_custom_prompt, :with_git_context, :with_metrics,
      project: project, goal: "create_issue", custom_prompt: "Analyze the auth system")
  end
  let(:github_client) { instance_double(GithubClient) }
  let(:issue_response) do
    Struct.new(:html_url, :number, :id, :title, :body, :state, :user, :labels, :created_at, :updated_at).new(
      "https://github.com/owner/repo/issues/10",
      10,
      12345,
      "Agent analysis",
      "Issue body",
      "open",
      Struct.new(:login).new("paid-bot"),
      [],
      Time.current,
      Time.current
    )
  end

  before do
    # These callbacks render/broadcast UI updates and are not part of this activity's behavior.
    allow(agent_run).to receive(:broadcast_project_updates)
    allow(agent_run).to receive(:update_project_last_agent_run_at)

    allow(Llm::GenerateIssueTitle).to receive(:call).and_return(nil)
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:create_issue).and_return(issue_response)
    allow(ProcessRunQueueJob).to receive(:perform_later)
  end

  describe "#execute" do
    it "creates a GitHub issue via the API" do
      expect(github_client).to receive(:create_issue).with(
        project.full_name,
        title: a_string_matching(/.+/),
        body: a_string_matching(/.+/),
        labels: [ "paid-generated" ]
      ).and_return(issue_response)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:issue_url]).to eq("https://github.com/owner/repo/issues/10")
      expect(result[:issue_number]).to eq(10)
    end

    it "marks the agent run as completed with issue details" do
      activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(agent_run.status).to eq("completed")
      expect(agent_run.created_issue_url).to eq("https://github.com/owner/repo/issues/10")
      expect(agent_run.created_issue_number).to eq(10)
    end

    it "logs the issue creation to agent run" do
      activity.execute(agent_run_id: agent_run.id)

      log = agent_run.agent_run_logs.last
      expect(log.log_type).to eq("system")
      expect(log.content).to include("https://github.com/owner/repo/issues/10")
    end

    it "triggers ProcessRunQueueJob" do
      expect(ProcessRunQueueJob).to receive(:perform_later)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "uses first markdown heading as title when agent output has one" do
      agent_run.log!("stdout", "# Authentication System Analysis\n\nThe auth system uses JWT tokens.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "Authentication System Analysis")
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "uses level-2 markdown heading as title" do
      agent_run.log!("stdout", "## Security Audit Results\n\nFindings listed below.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "Security Audit Results")
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "strips trailing markdown closing hashes from headings" do
      agent_run.log!("stdout", "## Security Audit Results ##\n\nFindings listed below.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "Security Audit Results")
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "falls back to LLM-generated title when no heading" do
      agent_run.log!("stdout", "The auth system uses JWT tokens.")
      allow(Llm::GenerateIssueTitle).to receive(:call).and_return("JWT authentication analysis")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "JWT authentication analysis")
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "falls back to default title when LLM returns nil" do
      agent_run.log!("stdout", "The auth system uses JWT tokens.")
      allow(Llm::GenerateIssueTitle).to receive(:call).and_return(nil)

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "Agent analysis")
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "falls back to default title when no stdout output" do
      no_prompt_run = create(:agent_run, :with_git_context, project: project,
        goal: "create_issue", custom_prompt: "Do analysis")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(title: "Agent analysis")
      ).and_return(issue_response)

      activity.execute(agent_run_id: no_prompt_run.id)
    end

    it "includes agent stdout in the issue body when available" do
      agent_run.log!("stdout", "Here is my analysis of the codebase.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(body: a_string_including("Here is my analysis"))
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "falls back to stderr content when no stdout is available" do
      agent_run.log!("stderr", "# Drafted Issue Title\n\nHere is detailed analysis from stderr.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Drafted Issue Title",
          body: a_string_including("detailed analysis from stderr")
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "prefers stdout over stderr when both are available" do
      agent_run.log!("stdout", "# Stdout Title\n\nStdout content.")
      agent_run.log!("stderr", "# Stderr Title\n\nStderr content.")

      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(
          title: "Stdout Title",
          body: a_string_including("Stdout content")
        )
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "uses fallback body when no stdout or stderr is available" do
      expect(github_client).to receive(:create_issue).with(
        anything,
        hash_including(body: a_string_including("automatically generated by"))
      ).and_return(issue_response)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "syncs the created issue to the local database" do
      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to change(Issue, :count).by(1)

      synced = project.issues.find_by(github_issue_id: 12345)
      expect(synced).to be_present
      expect(synced.github_number).to eq(10)
    end

    context "when auto_add_labels_enabled is false" do
      before { project.update!(auto_add_labels_enabled: false) }

      it "creates the issue with an empty labels array" do
        expect(github_client).to receive(:create_issue).with(
          project.full_name,
          hash_including(labels: [])
        ).and_return(issue_response)

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    context "when auto_add_labels_enabled is true with a custom generated label" do
      before { project.update!(auto_add_labels_enabled: true, generated_label_name: "my-label") }

      it "creates the issue with the custom label" do
        expect(github_client).to receive(:create_issue).with(
          project.full_name,
          hash_including(labels: [ "my-label" ])
        ).and_return(issue_response)

        activity.execute(agent_run_id: agent_run.id)
      end
    end

    it "raises ActiveRecord::RecordNotFound for invalid agent_run_id" do
      expect {
        activity.execute(agent_run_id: -1)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
