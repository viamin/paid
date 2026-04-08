# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CompleteExistingPrRunActivity do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :pull_request, project: project) }
  let(:agent_run) do
    create(:agent_run, :running, project: project, issue: issue,
      source_pull_request_number: 42,
      custom_prompt: "Fix review comments",
      result_commit_sha: "abc123def456789012345678901234567890abcd")
  end
  let(:activity) { described_class.new }
  let(:github_client) { instance_double(GithubClient) }
  let(:pr_head) { double("pr_head", ref: "fix-branch") } # rubocop:disable RSpec/VerifiedDoubles
  let(:pr_data) { double("pr_data", number: 42, html_url: "https://github.com/#{project.full_name}/pull/42", head: pr_head) } # rubocop:disable RSpec/VerifiedDoubles

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:pull_request)
      .with(project.full_name, 42)
      .and_return(pr_data)
    allow(github_client).to receive(:add_comment)
  end

  describe "#execute" do
    it "marks the agent run as completed with existing PR details" do
      activity.execute(agent_run_id: agent_run.id)

      agent_run.reload
      expect(agent_run.status).to eq("completed")
      expect(agent_run.pull_request_url).to eq("https://github.com/#{project.full_name}/pull/42")
      expect(agent_run.pull_request_number).to eq(42)
    end

    it "adds a comment with agent summary when stdout logs exist" do
      agent_run.log!("stdout", "Fixed the login validation bug by updating the form handler.")

      expect(github_client).to receive(:add_comment)
        .with(project.full_name, 42,
          "#{described_class::COMMENT_MARKER}\n#{described_class::SUMMARY_PREFIX}\n\nFixed the login validation bug by updating the form handler.")

      activity.execute(agent_run_id: agent_run.id)
    end

    it "adds a generic comment when no stdout logs exist" do
      expect(github_client).to receive(:add_comment)
        .with(project.full_name, 42, "#{described_class::COMMENT_MARKER}\n#{described_class::GENERIC_MESSAGE}")

      activity.execute(agent_run_id: agent_run.id)
    end

    it "identifies agent update comments" do
      expect(described_class.agent_update_comment?("#{described_class::COMMENT_MARKER}\nUpdate")).to be(true)
      expect(described_class.agent_update_comment?("## Agent Update\n\nLegacy summary")).to be(true)
      expect(described_class.agent_update_comment?("Agent pushed updates to this PR.")).to be(true)
      expect(described_class.agent_update_comment?("Please fix the parser error handling")).to be(false)
    end

    it "logs a system message" do
      activity.execute(agent_run_id: agent_run.id)

      log = agent_run.agent_run_logs.last
      expect(log.log_type).to eq("system")
      expect(log.content).to include("Pushed updates to existing PR")
    end

    it "updates issue paid_state to completed" do
      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.paid_state).to eq("completed")
    end

    it "returns agent_run_id and PR details including review phase" do
      result = activity.execute(agent_run_id: agent_run.id)

      expect(result[:agent_run_id]).to eq(agent_run.id)
      expect(result[:pull_request_url]).to eq("https://github.com/#{project.full_name}/pull/42")
      expect(result[:pull_request_number]).to eq(42)
      expect(result[:pr_review_phase]).to eq("ready")
    end

    it "enqueues ProcessRunQueueJob" do
      expect { activity.execute(agent_run_id: agent_run.id) }
        .to have_enqueued_job(ProcessRunQueueJob)
    end

    it "increments draft_review_count for successful tracked draft followups" do
      issue.update!(pr_review_phase: "draft", draft_review_count: 2)
      agent_run.update!(
        count_toward_draft_review_round: true,
        expected_draft_review_count: 2
      )

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.draft_review_count).to eq(3)
    end

    it "does not double-count tracked draft followups on retry" do
      issue.update!(pr_review_phase: "draft", draft_review_count: 2)
      agent_run.update!(
        count_toward_draft_review_round: true,
        expected_draft_review_count: 2
      )

      2.times { activity.execute(agent_run_id: agent_run.id) }

      expect(issue.reload.draft_review_count).to eq(3)
    end

    it "records the draft round before transitioning the run out of its active state" do
      issue.update!(pr_review_phase: "draft", draft_review_count: 2)
      agent_run.update!(
        count_toward_draft_review_round: true,
        expected_draft_review_count: 2
      )
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      expect(agent_run).to receive(:complete!).ordered.and_wrap_original do |method, **kwargs|
        expect(issue.reload.draft_review_count).to eq(3)
        method.call(**kwargs)
      end

      activity.execute(agent_run_id: agent_run.id)
    end

    it "handles comment failure gracefully" do
      allow(github_client).to receive(:add_comment)
        .and_raise(GithubClient::ApiError.new("forbidden", status: 403))

      expect { activity.execute(agent_run_id: agent_run.id) }.not_to raise_error
      expect(agent_run.reload.status).to eq("completed")
    end

    context "without an issue" do
      let(:agent_run) do
        create(:agent_run, :running, project: project, issue: nil,
          source_pull_request_number: 42,
          custom_prompt: "Fix review comments",
          result_commit_sha: "abc123def456789012345678901234567890abcd")
      end

      it "completes without updating issue state" do
        activity.execute(agent_run_id: agent_run.id)

        expect(agent_run.reload.status).to eq("completed")
      end
    end

    it "does not increment draft_review_count for untracked runs" do
      issue.update!(pr_review_phase: "draft", draft_review_count: 2)

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.draft_review_count).to eq(2)
    end

    it "does not increment draft_review_count for tracked runs with a non-running status" do
      issue.update!(pr_review_phase: "draft", draft_review_count: 2)
      agent_run.update!(
        status: "failed",
        count_toward_draft_review_round: true,
        expected_draft_review_count: 2
      )

      activity.execute(agent_run_id: agent_run.id)

      expect(issue.reload.draft_review_count).to eq(2)
    end
  end
end
