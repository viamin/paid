# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::EnhanceIssueActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:issue) do
    create(:issue, :in_progress,
      project: project,
      github_number: 42,
      title: "Add audit log",
      body: "Record user actions")
  end
  let(:agent_run) { create(:agent_run, project: project, issue: issue, goal: "enhance_issue") }
  let(:client) { instance_double(GithubClient) }
  let(:gh_issue) do
    OpenStruct.new(
      title: issue.title,
      number: issue.github_number,
      body: issue.body,
      user: OpenStruct.new(login: "viamin")
    )
  end
  let(:comments) do
    [
      OpenStruct.new(
        body: "Please include controller specs",
        user: OpenStruct.new(login: "maintainer"),
        created_at: Time.zone.parse("2026-04-20 12:00:00 UTC")
      )
    ]
  end
  let(:posted_comment) { OpenStruct.new(html_url: "https://github.com/owner/repo/issues/42#issuecomment-1") }
  let(:llm_output) do
    {
      sufficient_context: true,
      comment_body: "## Implementation context\n### Relevant files and symbols\n- `app/models/audit_log.rb`"
    }.to_json
  end
  let(:llm_response) do
    instance_double(
      AgentHarness::Response,
      success?: true,
      output: llm_output,
      tokens: true,
      input_tokens: 100,
      output_tokens: 40,
      model: "claude-sonnet-4-6"
    )
  end

  before do
    allow(activity).to receive(:github_client).and_return(client)
    allow(client).to receive(:issue).with(project.full_name, issue.github_number).and_return(gh_issue)
    allow(client).to receive(:issue_comments).with(project.full_name, issue.github_number).and_return(comments)
    allow(client).to receive(:add_comment).and_return(posted_comment)
    allow(Knowledge::Search).to receive(:call).and_return(
      results: [
        { title: "AuditLog", content: "app/models/audit_log.rb tracks user actions", path: "app/models/audit_log.rb" }
      ],
      meta: { total: 1 }
    )
    allow(Knowledge::ContextBundle::Build).to receive(:call).and_return(
      content: "## Codebase Context\n### Related Code\n- AuditLog",
      sections: [ :symbols ],
      total_tokens: 10
    )
    allow(AgentHarness).to receive(:send_message).and_return(llm_response)
    allow(ProcessRunQueueJob).to receive(:perform_later)
  end

  describe "#execute" do
    it "posts an implementation context comment" do
      result = activity.execute(agent_run_id: agent_run.id)

      expect(result).to include(
        agent_run_id: agent_run.id,
        issue_number: issue.github_number,
        comment_url: posted_comment.html_url,
        sufficient_context: true
      )
      expect(client).to have_received(:issue).with(project.full_name, issue.github_number)
      expect(client).to have_received(:issue_comments).with(project.full_name, issue.github_number)
      expect(client).to have_received(:add_comment).with(
        project.full_name,
        issue.github_number,
        a_string_including(described_class::COMMENT_MARKER, "## Implementation context")
      )
      expect(agent_run.reload.status).to eq("completed")
      expect(issue.reload.paid_state).to eq("completed")
      expect(agent_run.token_usages.last).to have_attributes(
        request_type: "agent",
        metadata: include("operation" => "enhance_issue")
      )
    end

    it "queries retrieval and context bundle knowledge" do
      activity.execute(agent_run_id: agent_run.id)

      expect(Knowledge::Search).to have_received(:call).with(hash_including(
        project: project,
        mode: "hybrid",
        limit: described_class::MAX_SEARCH_RESULTS
      ))
      expect(Knowledge::ContextBundle::Build).to have_received(:call).with(issue: issue, project: project)
    end

    it "posts clarifying questions when the LLM reports insufficient context" do
      allow(llm_response).to receive(:output).and_return(
        {
          sufficient_context: false,
          comment_body: "## Clarifying questions\n1. Which events should be recorded?"
        }.to_json
      )

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:sufficient_context]).to be false
      expect(client).to have_received(:add_comment).with(
        project.full_name,
        issue.github_number,
        a_string_including("## Clarifying questions", "Which events")
      )
    end

    it "does not post a duplicate enhancement comment when one already exists" do
      existing_comment = OpenStruct.new(
        body: "#{described_class::COMMENT_MARKER}\nExisting",
        html_url: "https://github.com/owner/repo/issues/42#issuecomment-0"
      )
      allow(client).to receive(:issue_comments).and_return([ existing_comment ])

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:already_enhanced]).to be true
      expect(client).not_to have_received(:add_comment)
      expect(AgentHarness).not_to have_received(:send_message)
      expect(agent_run.reload.status).to eq("completed")
      expect(issue.reload.paid_state).to eq("completed")
    end

    it "raises a non-retryable activity error when the LLM output is invalid JSON" do
      allow(llm_response).to receive(:output).and_return("not json")

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(Temporalio::Error::ApplicationError, "LLM returned invalid enhancement JSON")
    end
  end
end
