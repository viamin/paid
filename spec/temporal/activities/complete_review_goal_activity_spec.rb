# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CompleteReviewGoalActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:github_client) { instance_double(GithubClient) }

  def stub_review_lookup(agent_run, enabled_bot_logins: Set["paid-code-reviewer[bot]"])
    allow(AgentRun).to receive(:find).and_call_original
    allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
    allow(agent_run.project).to receive_messages(
      client: github_client,
      enabled_review_bot_logins: enabled_bot_logins
    )
  end

  describe "#execute" do
    context "when a review was posted" do
      it "marks the agent run as completed" do
        agent_run = create(:agent_run, :running, :review_goal, project: project,
          review_posted_at: 1.minute.ago)

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(agent_run.status).to eq("completed")
        expect(result[:success]).to be true
      end

      it "logs the completion" do
        agent_run = create(:agent_run, :running, :review_goal, project: project,
          review_posted_at: 1.minute.ago)

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to change(AgentRunLog, :count).by(1)

        log = agent_run.agent_run_logs.last
        expect(log.content).to include("review goal finished")
      end

      it "enqueues ProcessRunQueueJob" do
        agent_run = create(:agent_run, :running, :review_goal, project: project,
          review_posted_at: 1.minute.ago)

        expect { activity.execute(agent_run_id: agent_run.id) }
          .to have_enqueued_job(ProcessRunQueueJob)
      end

      it "resets review_goal_retry_count on the issue" do
        issue = create(:issue, project: project, review_goal_retry_count: 2)
        agent_run = create(:agent_run, :running, :review_goal, project: project,
          issue: issue, review_posted_at: 1.minute.ago)

        activity.execute(agent_run_id: agent_run.id)

        expect(issue.reload.review_goal_retry_count).to eq(0)
      end

      it "does not overwrite cancelled runs" do
        issue = create(:issue, project: project, review_goal_retry_count: 2)
        agent_run = create(:agent_run, :cancelled, :review_goal, project: project,
          issue: issue, review_posted_at: 1.minute.ago)

        result = activity.execute(agent_run_id: agent_run.id)

        expect(result[:success]).to be false
        expect(agent_run.reload.status).to eq("cancelled")
        expect(issue.reload.review_goal_retry_count).to eq(2)
      end
    end

    context "when no review was posted" do
      it "reconciles a GitHub review id from the agent output" do
        agent_run = create(:agent_run, :running, :review_goal, project: project)
        stub_review_lookup(agent_run)
        review_body = "Generated review body from the agent"
        agent_run.log!("stdout", "tool result: {\"success\":true,\"review_id\":123}")
        review = review_payload(id: 123, body: review_body)

        allow(github_client).to receive(:pull_request_reviews)
          .with(project.full_name, agent_run.source_pull_request_number)
          .and_return([ review ])

        result = activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(result[:success]).to be true
        expect(agent_run.status).to eq("completed")
        expect(agent_run.review_posted_at).to be_present
        expect(agent_run.review_url).to eq("#{project.github_url}/pull/10#pullrequestreview-123")
      end

      it "reconciles a Paid-marked GitHub review" do
        agent_run = create(:agent_run, :running, :review_goal, project: project)
        stub_review_lookup(agent_run)

        review = review_payload(
          id: 456,
          body: "#{described_class::PAID_REVIEW_MARKER}\n## Code Review\n\nGenerated no new comments."
        )

        allow(github_client).to receive(:pull_request_reviews)
          .with(project.full_name, agent_run.source_pull_request_number)
          .and_return([ review ])

        activity.execute(agent_run_id: agent_run.id)

        agent_run.reload
        expect(agent_run.status).to eq("completed")
        expect(agent_run.review_url).to eq("#{project.github_url}/pull/10#pullrequestreview-456")
      end

      it "fails the agent run with a message distinguishing no GitHub review from an untracked one" do
        agent_run = create(:agent_run, :running, :review_goal, project: project)
        stub_review_lookup(agent_run)
        allow(github_client).to receive(:pull_request_reviews).and_return([])

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.message).to include("no GitHub review exists")
          expect(error.type).to eq("ReviewNotPosted")
        }

        agent_run.reload
        expect(agent_run.status).to eq("failed")
        expect(agent_run.error_message).to include("no GitHub review exists")
      end

      it "includes proxy diagnostics in the failure message when available" do
        agent_run = create(:agent_run, :running, :review_goal, project: project,
          review_proxy_diagnostics: { "outcome" => "timeout" })
        stub_review_lookup(agent_run)
        allow(github_client).to receive(:pull_request_reviews).and_return([])

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /proxy POST timed out/)

        agent_run.reload
        expect(agent_run.error_message).to include("proxy POST timed out")
      end

      it "includes the upstream HTTP status when the proxy POST returned an upstream error" do
        agent_run = create(:agent_run, :running, :review_goal, project: project,
          review_proxy_diagnostics: { "outcome" => "upstream_error", "http_status" => 422 })
        stub_review_lookup(agent_run)
        allow(github_client).to receive(:pull_request_reviews).and_return([])

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError, /upstream error from GitHub \(HTTP 422\)/)
      end

      it "distinguishes an unverifiable GitHub review lookup from no GitHub review existing" do
        agent_run = create(:agent_run, :running, :review_goal, project: project,
          review_proxy_diagnostics: { "outcome" => "attempted" })
        stub_review_lookup(agent_run)
        allow(github_client).to receive(:pull_request_reviews).and_raise(GithubClient::Error.new("GitHub unavailable"))

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.message).to include("could not verify whether GitHub has a review")
          expect(error.message).to include("review lookup failed")
          expect(error.message).to include("proxy POST was attempted")
          expect(error.type).to eq("ReviewVerificationFailed")
        }

        agent_run.reload
        expect(agent_run.status).to eq("failed")
        expect(agent_run.error_message).not_to include("no GitHub review exists")
      end

      it "flags an untracked review that exists on GitHub but bypassed the tracking path" do
        agent_run = create(:agent_run, :running, :review_goal, project: project)
        stub_review_lookup(agent_run)
        agent_run.log!("stdout", "fetched existing review: A bot review that the agent never tracked")
        review = review_payload(id: 789, body: "A bot review that the agent never tracked")

        allow(github_client).to receive(:pull_request_reviews).and_return([ review ])

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.message).to include("No tracked review")
          expect(error.message).to include("id=789")
          expect(error.type).to eq("ReviewUntracked")
        }

        agent_run.reload
        expect(agent_run.status).to eq("failed")
        expect(agent_run.review_posted_at).to be_nil
        expect(agent_run.error_message).to include("bypassed the proxy tracking path")
      end

      it "ignores concurrent human reviews when checking for untracked Paid reviews" do
        agent_run = create(:agent_run, :running, :review_goal, project: project)
        stub_review_lookup(agent_run)
        review = review_payload(id: 790, user_login: "maintainer", body: "Human review left while the run was open")

        allow(github_client).to receive(:pull_request_reviews).and_return([ review ])

        expect {
          activity.execute(agent_run_id: agent_run.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |error|
          expect(error.message).to include("no GitHub review exists")
          expect(error.message).not_to include("bypassed the proxy tracking path")
          expect(error.type).to eq("ReviewNotPosted")
        }
      end
    end
  end

  def review_payload(id:, body:, user_login: "paid-code-reviewer[bot]")
    {
      id: id,
      user_login: user_login,
      state: "COMMENTED",
      body: body,
      submitted_at: Time.current
    }
  end
end
