# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe IssueEnhancements::StopForManualReview do
  let(:project) { create(:project) }
  let(:issue) do
    create(:issue, :needs_input,
      project: project,
      labels: [ project.enhance_issue_needs_input_label_name ],
      needs_input_questions: [ "Which behavior should ship?" ])
  end
  let(:client) { instance_double(GithubClient, issue_comments: [], remove_label_from_issue: true, add_comment: true) }

  before do
    allow(project).to receive(:client).and_return(client)
  end

  # @spec ISSUE-ENHANCEMENT-002, ISSUE-ENHANCEMENT-011
  it "clears the needs-input label and questions when requiring manual review" do
    described_class.call(project: project, issue: issue, reason: "Structured output was invalid.")

    expect(client).to have_received(:remove_label_from_issue).with(
      project.full_name,
      issue.github_number,
      project.enhance_issue_needs_input_label_name
    )
    expect(issue.reload).to have_attributes(paid_state: "manual_review", needs_input_questions: nil)
    expect(issue.labels).not_to include(project.enhance_issue_needs_input_label_name)
  end

  # @spec ISSUE-ENHANCEMENT-012
  it "persists the reason and stamps a durable entry timestamp" do
    freeze_time = Time.current
    travel_to(freeze_time) do
      described_class.call(project: project, issue: issue, reason: "Structured output was invalid.")
    end

    issue.reload
    expect(issue.manual_review_reason).to eq("Structured output was invalid.")
    expect(issue.manual_review_started_at).to be_within(1.second).of(freeze_time)
  end

  # @spec ISSUE-ENHANCEMENT-011
  it "still posts the stop notice when label removal fails" do
    allow(client).to receive(:remove_label_from_issue).and_raise(GithubClient::Error.new("label unavailable"))

    described_class.call(project: project, issue: issue, reason: "Round limit reached.")

    expect(client).to have_received(:add_comment).with(
      project.full_name,
      issue.github_number,
      a_string_including(described_class::COMMENT_MARKER, "Round limit reached.")
    )
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  # @spec ISSUE-ENHANCEMENT-011
  it "does not risk a duplicate stop notice when comment lookup fails" do
    allow(client).to receive(:issue_comments).and_raise(GithubClient::Error.new("comments unavailable"))

    described_class.call(project: project, issue: issue, reason: "Round limit reached.")

    expect(client).not_to have_received(:add_comment)
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  # @spec ISSUE-ENHANCEMENT-011
  it "does not let an untrusted marker suppress the Paid stop notice" do
    allow(client).to receive(:issue_comments).and_return([
      OpenStruct.new(
        body: described_class::COMMENT_MARKER,
        user: OpenStruct.new(login: "attacker")
      )
    ])

    described_class.call(project: project, issue: issue, reason: "Round limit reached.")

    expect(client).to have_received(:add_comment).once
  end

  # @spec ISSUE-ENHANCEMENT-011
  it "does not let an allowlisted collaborator's marker suppress the Paid stop notice" do
    # "viamin" is the default allowlisted human collaborator on the project
    # factory. trusted_github_user? admits them, but the marker text is just a
    # string — only Paid's bot-authored comments should be honored as a real
    # platform stop notice.
    allow(client).to receive(:issue_comments).and_return([
      OpenStruct.new(
        body: described_class::COMMENT_MARKER,
        user: OpenStruct.new(login: "viamin")
      )
    ])

    described_class.call(project: project, issue: issue, reason: "Round limit reached.")

    expect(client).to have_received(:add_comment).once
  end

  # @spec ISSUE-ENHANCEMENT-011
  it "honors a bot-authored marker comment for dedupe" do
    allow(project).to receive(:paid_bot_author?).and_call_original
    allow(project).to receive(:paid_bot_author?).with("paid-agents[bot]").and_return(true)
    allow(client).to receive(:issue_comments).and_return([
      OpenStruct.new(
        body: described_class::COMMENT_MARKER,
        user: OpenStruct.new(login: "paid-agents[bot]")
      )
    ])

    described_class.call(project: project, issue: issue, reason: "Round limit reached.")

    expect(client).not_to have_received(:add_comment)
  end

  # @spec ISSUE-ENHANCEMENT-011
  it "does not publish again after another worker has already parked the issue" do
    issue.update!(paid_state: "manual_review")

    described_class.call(project: project, issue: issue, reason: "Round limit reached.")

    expect(client).not_to have_received(:issue_comments)
    expect(client).not_to have_received(:add_comment)
    expect(issue.reload.labels).not_to include(project.enhance_issue_needs_input_label_name)
  end
end
