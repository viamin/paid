# frozen_string_literal: true

require "rails_helper"

RSpec.describe Reviews::Verification::PostTrackedReview do
  let(:project) { create(:project) }
  let(:agent_run) do
    create(:agent_run, project: project, goal: "review",
      source_pull_request_number: 42, status: "running")
  end
  let(:bot_token) { "bot-installation-token" }
  let(:bot_client) { instance_double(GithubClient) }
  let(:created_review) do
    instance_double(Sawyer::Resource).tap do |resource|
      allow(resource).to receive_messages(
        id: 987_654,
        html_url: "https://github.com/#{project.full_name}/pull/42#pullrequestreview-987654"
      )
    end
  end

  before do
    allow(Github::ReviewBotInstallationToken).to receive(:new).and_return(
      instance_double(Github::ReviewBotInstallationToken, fetch: bot_token)
    )
    allow(GithubClient).to receive(:new).with(token: bot_token).and_return(bot_client)
    allow(bot_client).to receive(:create_pull_request_review_payload).and_return(created_review)
  end

  describe ".call" do
    # @spec REVIEW-VERIFY-006
    it "posts one COMMENT review under the review-bot token with the Paid marker and pinned commit" do
      result = described_class.call(
        agent_run: agent_run,
        body: "Found one issue.",
        comments: [ { path: "app/foo.rb", line: 3, side: "RIGHT", body: "Fix this." } ],
        commit_sha: "pinnedsha123"
      )

      expect(bot_client).to have_received(:create_pull_request_review_payload).with(
        project.full_name, 42,
        {
          body: a_string_starting_with(Github::ReviewMarker::PAID_REVIEW_MARKER)
            .and(include("## Code Review", "Found one issue.")),
          event: "COMMENT",
          commit_id: "pinnedsha123",
          comments: [ { path: "app/foo.rb", line: 3, side: "RIGHT", body: "Fix this." } ]
        }
      )
      expect(result[:review_id]).to eq(987_654)
      expect(result[:already_posted]).to be false

      agent_run.reload
      expect(agent_run.review_posted_at).to be_present
      expect(agent_run.review_url).to eq(created_review.html_url)
    end

    # @spec REVIEW-VERIFY-006
    it "does not post a second review when the run already posted one" do
      agent_run.update!(review_posted_at: 5.minutes.ago, review_url: "https://example.com/review/1")

      result = described_class.call(
        agent_run: agent_run, body: "again", comments: [], commit_sha: "sha"
      )

      expect(result[:already_posted]).to be true
      expect(result[:review_url]).to eq("https://example.com/review/1")
      expect(bot_client).not_to have_received(:create_pull_request_review_payload)
    end

    it "recovers from a pending-review 422 by deleting the pending review and retrying once" do
      pending_review = { id: 111, state: "PENDING", user_login: "paid-code-reviewer[bot]" }
      allow(bot_client).to receive(:pull_request_reviews).and_return([ pending_review ])
      allow(bot_client).to receive(:delete_pending_pull_request_review).and_return(true)
      allow(bot_client).to receive(:create_pull_request_review_payload)
        .and_raise(GithubClient::ApiError.new("Only one pending review per pull request is allowed", status: 422))
        .and_return(created_review)

      described_class.call(agent_run: agent_run, body: "body", comments: [], commit_sha: "sha")

      expect(bot_client).to have_received(:delete_pending_pull_request_review)
        .with(project.full_name, 42, 111)
      expect(bot_client).to have_received(:create_pull_request_review_payload).twice
      expect(agent_run.reload.review_posted_at).to be_present
    end

    it "does not swallow unrelated upstream errors" do
      allow(bot_client).to receive(:create_pull_request_review_payload)
        .and_raise(GithubClient::ApiError.new("Validation Failed", status: 422))

      expect {
        described_class.call(agent_run: agent_run, body: "body", comments: [], commit_sha: "sha")
      }.to raise_error(GithubClient::ApiError)

      expect(agent_run.reload.review_posted_at).to be_blank
    end
  end
end
