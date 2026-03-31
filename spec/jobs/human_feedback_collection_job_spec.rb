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
          pull_request: { review_comments: 1 }
        )

        described_class.new.perform(agent_run.id)

        metric = agent_run.quality_metrics.human.first
        expect(metric).to be_present
        expect(metric.scores).to include("reaction_score", "review_score")
      end

      it "updates scores and composite_score when storing review comment count" do
        agent_run = create(:agent_run, :completed)
        metric = create(:quality_metric, :automated, agent_run: agent_run,
          scores: { "pr_created" => 1.0, "iterations" => 0.8 })
        allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
        allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

        allow(github_client).to receive_messages(
          pull_request_reactions: [],
          pull_request_reviews: [],
          pull_request: { review_comments: 2 }
        )

        described_class.new.perform(agent_run.id)

        metric.reload
        expect(metric.scores["review_comment_count"]).to eq(0.8)
        expect(metric.metadata["review_comment_count"]).to eq(2)
        expect(metric.composite_score).to be_present
      end

      it "re-enqueues with incremented attempt when automated metric is missing" do
        agent_run = create(:agent_run, :completed)
        # No automated metric created
        allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
        allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

        allow(github_client).to receive_messages(
          pull_request_reactions: [],
          pull_request_reviews: [],
          pull_request: { review_comments: 3 }
        )

        expect {
          described_class.new.perform(agent_run.id)
        }.to have_enqueued_job(described_class).with(agent_run.id, comment_count_attempt: 1)
      end

      it "stops re-enqueuing after max attempts" do
        agent_run = create(:agent_run, :completed)
        allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
        allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

        allow(github_client).to receive_messages(
          pull_request_reactions: [],
          pull_request_reviews: [],
          pull_request: { review_comments: 3 }
        )

        expect {
          described_class.new.perform(agent_run.id, comment_count_attempt: described_class::MAX_COMMENT_COUNT_ATTEMPTS)
        }.not_to have_enqueued_job(described_class)
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

        allow(github_client).to receive(:pull_request_review_comments).and_return([
          { id: 101, user_login: "carol", body: "nice approach", created_at: 1.hour.ago }
        ])
        allow(github_client).to receive(:pull_request_review_comment_reactions)
          .with(agent_run.project.full_name, 101)
          .and_return([
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

    it "stamps last_polled_at in human metric metadata after collection" do
      agent_run = create(:agent_run, :completed)
      create(:quality_metric, :automated, agent_run: agent_run)
      allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      allow(github_client).to receive_messages(
        pull_request_reactions: [
          { user_login: "alice", content: "+1", created_at: 1.hour.ago }
        ],
        pull_request_reviews: [],
        pull_request: { review_comments: 0 }
      )

      freeze_time do
        described_class.new.perform(agent_run.id)

        metric = agent_run.quality_metrics.human.reload.first
        expect(metric).to be_present
        expect(metric.metadata["last_polled_at"]).to eq(Time.current.iso8601)
      end
    end

    it "creates a human metric with last_polled_at when no reactions or reviews are collected" do
      agent_run = create(:agent_run, :completed)
      create(:quality_metric, :automated, agent_run: agent_run)
      allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      allow(github_client).to receive_messages(
        pull_request_reactions: [],
        pull_request_reviews: [],
        pull_request: { review_comments: 0 }
      )

      freeze_time do
        described_class.new.perform(agent_run.id)

        metric = agent_run.quality_metrics.human.first
        expect(metric).to be_present
        expect(metric.metadata["last_polled_at"]).to eq(Time.current.iso8601)
        expect(metric.scores).to eq({})
      end
    end

    it "handles GitHub API errors for reviews gracefully" do
      agent_run = create(:agent_run, :completed)
      allow(agent_run.project.github_token).to receive(:client).and_return(github_client)
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      allow(github_client).to receive(:pull_request_reactions).and_return([])
      allow(github_client).to receive(:pull_request_reviews)
        .and_raise(GithubClient::ApiError.new("rate limited"))
      allow(github_client).to receive(:pull_request)
        .and_raise(GithubClient::ApiError.new("rate limited"))

      expect {
        described_class.new.perform(agent_run.id)
      }.not_to raise_error
    end
  end
end
