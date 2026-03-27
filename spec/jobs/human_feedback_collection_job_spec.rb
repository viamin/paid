# frozen_string_literal: true

require "rails_helper"

RSpec.describe HumanFeedbackCollectionJob do
  describe "#perform" do
    let(:github_client) { instance_double(GithubClient) }

    context "with create_pr goal" do
      it "collects reactions, reviews, and comment count for completed PR" do
        agent_run = create(:agent_run, :completed)
        # Create automated metric so review comment count can be stored
        create(:quality_metric, :automated, agent_run: agent_run)
        allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
        allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

        allow(github_client).to receive_messages(
          pull_request_reactions: [
            { user_login: "alice", content: "+1", created_at: 1.hour.ago }
          ],
          pull_request_reviews: [
            { state: "APPROVED", user_login: "bob", body: "LGTM" }
          ],
          pull_request_review_comments: [
            { id: 1, user_login: "bob", body: "nit", created_at: 1.hour.ago }
          ]
        )

        described_class.new.perform(agent_run.id)

        metric = agent_run.quality_metrics.human.first
        expect(metric).to be_present
        expect(metric.scores).to include("reaction_score", "review_score")
      end

      it "skips PR runs without pull request number" do
        agent_run = create(:agent_run, :failed)

        expect {
          described_class.new.perform(agent_run.id)
        }.not_to change(QualityMetric, :count)
      end
    end

    context "with create_issue goal" do
      it "collects issue reactions for completed issue creation" do
        agent_run = create(:agent_run, :with_created_issue, status: "completed",
          started_at: 10.minutes.ago, completed_at: Time.current, duration_seconds: 600)
        allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
        allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

        allow(github_client).to receive(:issue_reactions).and_return([
          { user_login: "alice", content: "+1", created_at: 1.hour.ago }
        ])

        described_class.new.perform(agent_run.id)

        metric = agent_run.quality_metrics.human.first
        expect(metric).to be_present
        expect(metric.scores).to include("reaction_score")
        expect(metric.metadata["feedback_sources"]).to include("issue_reaction")
      end
    end

    context "with review goal" do
      it "collects review reactions for completed code review" do
        agent_run = create(:agent_run, :with_review)
        allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
        allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

        allow(github_client).to receive(:issue_reactions).and_return([
          { user_login: "alice", content: "rocket", created_at: 1.hour.ago }
        ])

        described_class.new.perform(agent_run.id)

        metric = agent_run.quality_metrics.human.first
        expect(metric).to be_present
        expect(metric.scores).to include("reaction_score")
        expect(metric.metadata["feedback_sources"]).to include("review_reaction")
      end
    end

    it "skips agent runs that are not finished" do
      agent_run = create(:agent_run, :running, pull_request_number: 1)

      expect {
        described_class.new.perform(agent_run.id)
      }.not_to change(QualityMetric, :count)
    end

    it "handles GitHub API errors for reviews gracefully" do
      agent_run = create(:agent_run, :completed)
      allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      allow(github_client).to receive(:pull_request_reactions).and_return([])
      allow(github_client).to receive(:pull_request_reviews)
        .and_raise(GithubClient::ApiError.new("rate limited"))
      allow(github_client).to receive(:pull_request_review_comments)
        .and_raise(GithubClient::ApiError.new("rate limited"))

      expect {
        described_class.new.perform(agent_run.id)
      }.not_to raise_error
    end
  end
end
