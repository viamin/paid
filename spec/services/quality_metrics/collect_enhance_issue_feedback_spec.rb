# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe QualityMetrics::CollectEnhanceIssueFeedback do
  describe ".call" do
    let(:agent_run) { create(:agent_run, :enhance_issue_goal, :completed, pull_request_number: nil) }
    let(:github_client) { instance_double(GithubClient) }
    let(:enhancement_comment) do
      OpenStruct.new(
        id: 123,
        body: "#{Activities::EnhanceIssueActivity::COMMENT_MARKER}\n## Implementation context",
        created_at: 2.hours.ago,
        user: OpenStruct.new(login: "paid-agent")
      )
    end
    let(:author_reply) do
      OpenStruct.new(
        id: 124,
        body: "Thanks, this helps.",
        created_at: 1.hour.ago,
        user: OpenStruct.new(login: agent_run.issue.github_creator_login)
      )
    end
    let(:scored_reactions) do
      [
        { user_login: "alice", content: "+1", created_at: 1.hour.ago },
        { user_login: "bob", content: "-1", created_at: 30.minutes.ago },
        { user_login: "carol", content: "heart", created_at: 15.minutes.ago }
      ]
    end

    before do
      allow(agent_run.project).to receive_messages(
        github_credential_present?: true,
        client: github_client
      )
    end

    it "records reaction score and issue author reply for the enhancement comment" do
      allow(github_client).to receive(:issue_comments).and_return([ enhancement_comment, author_reply ])
      allow(github_client).to receive(:issue_comment_reactions).with(agent_run.project.full_name, 123).and_return(scored_reactions)

      metric = described_class.call(agent_run: agent_run)

      expect(metric).to be_persisted
      expect(metric.metric_type).to eq("human")
      expect(metric.scores).to include(
        "reaction_score" => 0.6667,
        "author_replied" => 1.0
      )
      expect(metric.metadata["feedback_sources"]).to include("enhance_issue_feedback")
      expect(metric.metadata["reaction_counts"]).to include("+1" => 1, "-1" => 1, "heart" => 1)
    end

    it "records author_replied as 0 when the author has not replied" do
      allow(github_client).to receive_messages(
        issue_comments: [ enhancement_comment ],
        issue_comment_reactions: []
      )

      metric = described_class.call(agent_run: agent_run)

      expect(metric.scores).to eq("author_replied" => 0.0)
      expect(metric.composite_score).to eq(0.0)
    end

    it "returns nil when the enhancement comment cannot be found" do
      allow(github_client).to receive(:issue_comments).and_return([])

      result = described_class.call(agent_run: agent_run)

      expect(result).to be_nil
    end
  end
end
