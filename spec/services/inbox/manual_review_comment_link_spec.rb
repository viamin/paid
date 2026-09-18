# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewCommentLink do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, paid_state: "manual_review") }
  let(:client) { instance_double(GithubClient) }

  before do
    allow(project).to receive(:client).and_return(client)
  end

  # @spec OPERATOR-INBOX-002D
  it "returns the html_url of the paid-bot marker comment" do
    marker_comment = double(
      body: "#{IssueEnhancements::StopForManualReview::COMMENT_MARKER}\n## Auto-enhancement stopped",
      user: double(login: "paid-agents[bot]"),
      html_url: "#{issue.github_url}#issuecomment-1"
    )
    allow(client).to receive(:issue_comments).and_return([ marker_comment ])
    allow(project).to receive(:paid_bot_author?).with("paid-agents[bot]").and_return(true)

    expect(described_class.call(project: project, issue: issue)).to eq(marker_comment.html_url)
  end

  # @spec OPERATOR-INBOX-002D
  it "returns the latest matching comment when several are present" do
    older = double(
      body: IssueEnhancements::StopForManualReview::COMMENT_MARKER,
      user: double(login: "paid-agents[bot]"),
      html_url: "#{issue.github_url}#issuecomment-1"
    )
    newer = double(
      body: IssueEnhancements::StopForManualReview::COMMENT_MARKER,
      user: double(login: "paid-agents[bot]"),
      html_url: "#{issue.github_url}#issuecomment-2"
    )
    allow(client).to receive(:issue_comments).and_return([ older, newer ])
    allow(project).to receive(:paid_bot_author?).with("paid-agents[bot]").and_return(true)

    expect(described_class.call(project: project, issue: issue)).to eq(newer.html_url)
  end

  # @spec OPERATOR-INBOX-002D
  it "ignores comments that carry the marker but were not authored by the paid bot" do
    forged = double(
      body: IssueEnhancements::StopForManualReview::COMMENT_MARKER,
      user: double(login: "some-human"),
      html_url: "#{issue.github_url}#issuecomment-1"
    )
    allow(client).to receive(:issue_comments).and_return([ forged ])
    allow(project).to receive(:paid_bot_author?).with("some-human").and_return(false)

    expect(described_class.call(project: project, issue: issue)).to be_nil
  end

  # @spec OPERATOR-INBOX-002D
  it "returns nil when no comment carries the marker" do
    unrelated = double(
      body: "Just a regular comment.",
      user: double(login: "paid-agents[bot]")
    )
    allow(client).to receive(:issue_comments).and_return([ unrelated ])
    allow(project).to receive(:paid_bot_author?).and_return(true)

    expect(described_class.call(project: project, issue: issue)).to be_nil
  end

  # @spec OPERATOR-INBOX-002D
  it "returns nil without calling GitHub when the project has no credential" do
    allow(project).to receive(:github_credential_present?).and_return(false)
    allow(client).to receive(:issue_comments)

    expect(described_class.call(project: project, issue: issue)).to be_nil
    expect(client).not_to have_received(:issue_comments)
  end

  # @spec OPERATOR-INBOX-002D
  it "returns nil when the GitHub lookup raises" do
    allow(client).to receive(:issue_comments).and_raise(GithubClient::Error.new("rate limited"))

    expect(described_class.call(project: project, issue: issue)).to be_nil
  end

  # @spec OPERATOR-INBOX-002D
  it "returns nil without raising when the project's GitHub installation is inactive" do
    allow(project).to receive_messages(github_credential_present?: true, client: nil)

    expect(described_class.call(project: project, issue: issue)).to be_nil
  end
end
