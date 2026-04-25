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
    allow(GithubClient).to receive(:new).and_return(client)
    allow(client).to receive(:issue).with(project.full_name, issue.github_number).and_return(gh_issue)
    allow(client).to receive(:issue_comments).with(project.full_name, issue.github_number).and_return(comments)
    allow(client).to receive(:add_comment).and_return(posted_comment)
    allow(client).to receive(:add_labels_to_issue)
    allow(client).to receive(:remove_label_from_issue)
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

  def expect_label_added(label)
    expect(client).to have_received(:add_labels_to_issue).with(
      project.full_name,
      issue.github_number,
      [ label ]
    )
  end

  def expect_comment_including(*parts)
    expect(client).to have_received(:add_comment).with(
      project.full_name,
      issue.github_number,
      a_string_including(*parts)
    )
  end

  def answered_reevaluation_comments
    [
      OpenStruct.new(
        body: "#{described_class::COMMENT_MARKER}\n## Clarifying questions\n1. Which events should be recorded?",
        user: OpenStruct.new(login: "paid-code-reviewer[bot]"),
        created_at: Time.zone.parse("2026-04-20 12:00:00 UTC")
      ),
      OpenStruct.new(
        body: "Record sign-in, permission, and billing events.",
        user: OpenStruct.new(login: "viamin"),
        created_at: Time.zone.parse("2026-04-20 13:00:00 UTC")
      )
    ]
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
      expect_comment_including(described_class::COMMENT_MARKER, "## Implementation context")
      expect(agent_run.reload.status).to eq("completed")
      expect(issue.reload.paid_state).to eq("completed")
      expect(issue.labels).to include(project.enhance_issue_enhanced_label_name)
      expect_label_added(project.enhance_issue_enhanced_label_name)
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
      expect(Knowledge::ContextBundle::Build).to have_received(:call).with(issue: issue, project: project, agent_run: agent_run)
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
      expect(result[:label_applied]).to eq(project.enhance_issue_needs_input_label_name)
      expect_comment_including("## Clarifying questions", "Which events")
      expect_label_added(project.enhance_issue_needs_input_label_name)
      expect(issue.reload.paid_state).to eq("needs_input")
      expect(issue.labels).to include(project.enhance_issue_needs_input_label_name)
    end

    it "fails before moving to needs_input when adding the GitHub label fails" do
      allow(client).to receive(:add_labels_to_issue).and_raise(GithubClient::Error.new("GitHub unavailable"))
      allow(llm_response).to receive(:output).and_return(
        {
          sufficient_context: false,
          comment_body: "## Clarifying questions\n1. Which events should be recorded?"
        }.to_json
      )

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(
        Temporalio::Error::ApplicationError,
        "Failed to apply enhance_issue control label #{project.enhance_issue_needs_input_label_name}"
      )

      expect(client).to have_received(:add_comment).with(
        project.full_name,
        issue.github_number,
        a_string_including("## Clarifying questions")
      )
      expect(issue.reload.paid_state).to eq("in_progress")
      expect(issue.reload.labels).not_to include(project.enhance_issue_needs_input_label_name)
    end

    it "fails before completing when adding the enhanced GitHub label fails" do
      allow(client).to receive(:add_labels_to_issue).and_raise(GithubClient::Error.new("GitHub unavailable"))

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(
        Temporalio::Error::ApplicationError,
        "Failed to apply enhance_issue control label #{project.enhance_issue_enhanced_label_name}"
      )

      expect(client).to have_received(:add_comment).with(
        project.full_name,
        issue.github_number,
        a_string_including("## Implementation context")
      )
      expect(issue.reload.paid_state).to eq("in_progress")
      expect(issue.reload.labels).not_to include(project.enhance_issue_enhanced_label_name)
    end

    it "does not apply labels when posting the enhancement comment fails" do
      allow(client).to receive(:add_comment).and_raise(GithubClient::Error.new("GitHub unavailable"))

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(GithubClient::Error, "GitHub unavailable")

      expect(client).not_to have_received(:add_labels_to_issue)
      expect(issue.reload.paid_state).to eq("in_progress")
      expect(issue.labels).not_to include(project.enhance_issue_enhanced_label_name)
    end

    it "posts a manual-review stop comment instead of reapplying needs-input at the max round" do
      issue.update!(enhance_issue_rounds: project.max_enhance_issue_reevaluation_rounds)
      allow(llm_response).to receive(:output).and_return(
        {
          sufficient_context: false,
          comment_body: "## Clarifying questions\n1. Which events should be recorded?"
        }.to_json
      )

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:max_rounds_reached]).to be true
      expect(result[:label_applied]).to be_nil
      expect_comment_including("## Auto-enhancement stopped", "Manual review is needed")
      expect(client).not_to have_received(:add_labels_to_issue).with(
        project.full_name,
        issue.github_number,
        [ project.enhance_issue_needs_input_label_name ]
      )
      expect(issue.reload.paid_state).to eq("completed")
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
      expect(issue.labels).to include(project.enhance_issue_enhanced_label_name)
    end

    it "keeps an existing clarifying-question enhancement in needs_input" do
      issue.update!(labels: [ project.enhance_issue_needs_input_label_name ])
      existing_comment = OpenStruct.new(
        body: "#{described_class::COMMENT_MARKER}\n## Clarifying questions\n1. Which events should be recorded?",
        html_url: "https://github.com/owner/repo/issues/42#issuecomment-0"
      )
      allow(client).to receive(:issue_comments).and_return([ existing_comment ])

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:already_enhanced]).to be true
      expect(client).not_to have_received(:add_comment)
      expect(AgentHarness).not_to have_received(:send_message)
      expect(agent_run.reload.status).to eq("completed")
      expect(issue.reload.paid_state).to eq("needs_input")
    end

    it "reconciles the needs-input label after a prior comment-only retry" do
      existing_comment = OpenStruct.new(
        body: "#{described_class::COMMENT_MARKER}\n## Clarifying questions\n1. Which events should be recorded?",
        html_url: "https://github.com/owner/repo/issues/42#issuecomment-0"
      )
      allow(client).to receive(:issue_comments).and_return([ existing_comment ])

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:already_enhanced]).to be true
      expect(result[:sufficient_context]).to be false
      expect(result[:label_applied]).to eq(project.enhance_issue_needs_input_label_name)
      expect(client).not_to have_received(:add_comment)
      expect(AgentHarness).not_to have_received(:send_message)
      expect_label_added(project.enhance_issue_needs_input_label_name)
      expect(agent_run.reload.status).to eq("completed")
      expect(issue.reload.paid_state).to eq("needs_input")
      expect(issue.labels).to include(project.enhance_issue_needs_input_label_name)
    end

    it "reconciles the enhanced label after a prior comment-only retry" do
      existing_comment = OpenStruct.new(
        body: "#{described_class::COMMENT_MARKER}\n## Implementation context\n### Relevant files and symbols\n- `app/models/audit_log.rb`",
        html_url: "https://github.com/owner/repo/issues/42#issuecomment-0"
      )
      allow(client).to receive(:issue_comments).and_return([ existing_comment ])

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:already_enhanced]).to be true
      expect(result[:sufficient_context]).to be true
      expect(result[:label_applied]).to eq(project.enhance_issue_enhanced_label_name)
      expect(client).not_to have_received(:add_comment)
      expect(AgentHarness).not_to have_received(:send_message)
      expect_label_added(project.enhance_issue_enhanced_label_name)
      expect(agent_run.reload.status).to eq("completed")
      expect(issue.reload.paid_state).to eq("completed")
      expect(issue.labels).to include(project.enhance_issue_enhanced_label_name)
    end

    it "keeps retrying an existing clarifying-question enhancement when label reconciliation fails" do
      existing_comment = OpenStruct.new(
        body: "#{described_class::COMMENT_MARKER}\n## Clarifying questions\n1. Which events should be recorded?",
        html_url: "https://github.com/owner/repo/issues/42#issuecomment-0"
      )
      allow(client).to receive(:issue_comments).and_return([ existing_comment ])
      allow(client).to receive(:add_labels_to_issue).and_raise(GithubClient::Error.new("GitHub unavailable"))

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(
        Temporalio::Error::ApplicationError,
        "Failed to apply enhance_issue control label #{project.enhance_issue_needs_input_label_name}"
      )

      expect(client).not_to have_received(:add_comment)
      expect(AgentHarness).not_to have_received(:send_message)
      expect(agent_run.reload.status).to eq("running")
      expect(issue.reload.paid_state).to eq("in_progress")
      expect(issue.labels).not_to include(project.enhance_issue_needs_input_label_name)
    end

    it "keeps an existing max-round stop comment completed" do
      existing_comment = OpenStruct.new(
        body: "#{described_class::COMMENT_MARKER}\n## Auto-enhancement stopped\n\n## Latest context\n## Clarifying questions",
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

    it "raises GitHub API failures before calling the LLM" do
      allow(client).to receive(:issue).and_raise(GithubClient::Error.new("GitHub unavailable"))

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(GithubClient::Error, "GitHub unavailable")

      expect(AgentHarness).not_to have_received(:send_message)
    end

    it "continues with fallback context when the knowledge base is unavailable" do
      allow(Knowledge::Search).to receive(:call).and_raise(StandardError, "index unavailable")
      allow(Knowledge::ContextBundle::Build).to receive(:call).and_raise(StandardError, "bundle unavailable")

      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:sufficient_context]).to be true
      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including("No retrieval results.", "No context bundle entries were available."),
        hash_including(provider: :claude)
      )
    end

    it "re-evaluates using all comments including the user's answers" do
      issue.update!(enhance_issue_rounds: 1)
      allow(client).to receive(:issue_comments).and_return(answered_reevaluation_comments)

      activity.execute(agent_run_id: agent_run.id)

      expect(AgentHarness).to have_received(:send_message).with(
        a_string_including(
          "Which events should be recorded?",
          "Record sign-in, permission, and billing events."
        ),
        hash_including(provider: :claude)
      )
      expect_comment_including("## Implementation context")
      expect(issue.reload.enhance_issue_rounds).to eq(1)
    end
  end
end
