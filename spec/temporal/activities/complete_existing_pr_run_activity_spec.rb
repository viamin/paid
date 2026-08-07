# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CompleteExistingPrRunActivity do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, :pull_request, project: project) }
  let(:agent_run) do
    create(:agent_run, :running, project: project, issue: issue,
      source_pull_request_number: 42,
      custom_prompt: "Fix review comments",
      base_commit_sha: "def123def456789012345678901234567890abcd",
      result_commit_sha: "abc123def456789012345678901234567890abcd")
  end
  let(:activity) { described_class.new }
  let(:github_client) { instance_double(GithubClient) }
  let(:pr_head) { double("pr_head", ref: "fix-branch") } # rubocop:disable RSpec/VerifiedDoubles
  let(:pr_data) { double("pr_data", number: 42, html_url: "https://github.com/#{project.full_name}/pull/42", head: pr_head) } # rubocop:disable RSpec/VerifiedDoubles
  let(:summary_response) do
    instance_double(
      AgentHarness::Response,
      success?: true,
      output: "## Summary\n\n- Tightened provider validation.",
      tokens: true,
      input_tokens: 120,
      output_tokens: 30,
      model: "claude-sonnet-4-6"
    )
  end
  let(:summary_comparison) do
    {
      commits: [
        { sha: agent_run.result_commit_sha, message: "fix: tighten provider validation" }
      ],
      files: [
        { filename: "app/models/provider.rb", status: "modified", additions: 3, deletions: 1, patch: "@@ changed" }
      ]
    }
  end
  let(:summary_base_sha) { agent_run.external_metadata["pre_run_head_sha"] }

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

    it "does not add an update comment by default" do
      agent_run.log!("stdout", "Fixed the login validation bug by updating the form handler.")

      expect(github_client).not_to receive(:compare_summary)
      expect(github_client).not_to receive(:add_comment)

      activity.execute(agent_run_id: agent_run.id)
    end

    # @spec LID-RUNS-003
    it "does not spam a coherence soft-block followup comment (#3272)" do
      agent_run.update!(
        external_metadata: {
          "pre_run_head_sha" => "fedcba9876543210012345678901234567890abc",
          "lid_coherence" => {
            "status" => "failed",
            "summary_line" => "Coherence soft-block: 1 reverse orphan."
          }
        }
      )

      expect(github_client).not_to receive(:compare_summary)
      expect(github_client).not_to receive(:add_comment)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "adds a generated summary comment when summary comments are enabled" do
      enable_summary_comments
      allow(TokenUsageTracker).to receive(:track).and_call_original

      expect(github_client).to receive(:add_comment)
        .with(project.full_name, 42,
          "#{described_class::COMMENT_MARKER}\n#{described_class::SUMMARY_PREFIX}\n\n## Summary\n\n- Tightened provider validation.")

      activity.execute(agent_run_id: agent_run.id)

      usage = agent_run.token_usages.last
      expect(usage.request_type).to eq("agent")
      expect(usage.metadata).to include("operation" => "agent_update_summary")
      expect(TokenUsageTracker).to have_received(:track).with(
        tracked_run: agent_run,
        usage: hash_including(metadata: { operation: "agent_update_summary" }),
        enforce_guardrails: false
      )
    end

    it "summarizes only the new push when a pre-run PR head SHA was recorded" do
      agent_run.update!(external_metadata: { "pre_run_head_sha" => "fedcba9876543210012345678901234567890abc" })
      enable_summary_comments

      expect(github_client).to receive(:compare_summary)
        .with(project.full_name, "fedcba9876543210012345678901234567890abc", agent_run.result_commit_sha)
        .and_return(summary_comparison)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "skips the comment when summary comments are enabled but no commit range exists" do
      project.effective_owner.settings.update!(agent_update_comment_mode: "summary")

      expect(github_client).not_to receive(:compare_summary)
      expect(github_client).not_to receive(:add_comment)

      activity.execute(agent_run_id: agent_run.id)
    end

    it "skips the comment when summary generation fails" do
      enable_summary_comments
      allow(AgentHarness).to receive(:send_message).and_return(
        instance_double(
          AgentHarness::Response,
          success?: false,
          output: "",
          tokens: true,
          input_tokens: 90,
          output_tokens: 0,
          model: "claude-sonnet-4-6"
        )
      )

      expect(github_client).not_to receive(:add_comment)

      expect { activity.execute(agent_run_id: agent_run.id) }
        .to change(agent_run.token_usages, :count).by(1)
    end

    it "tracks tokens even when summary generation returns a blank body" do
      enable_summary_comments
      allow(AgentHarness).to receive(:send_message).and_return(
        instance_double(
          AgentHarness::Response,
          success?: true,
          output: %(\n```markdown\n```\n),
          tokens: true,
          input_tokens: 75,
          output_tokens: 4,
          model: "claude-sonnet-4-6"
        )
      )

      expect(github_client).not_to receive(:add_comment)

      expect { activity.execute(agent_run_id: agent_run.id) }
        .to change(agent_run.token_usages, :count).by(1)
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

    it "reports cancellation when the run is already cancelled" do
      agent_run.cancel!

      expect(github_client).not_to receive(:pull_request)
      expect(github_client).not_to receive(:add_comment)

      result = activity.execute(agent_run_id: agent_run.id)

      expect(agent_run.reload.status).to eq("cancelled")
      expect(issue.reload.paid_state).not_to eq("completed")
      expect(result).to include(skipped: true, cancelled: true)
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

    it "records the draft round only after the run completes successfully" do
      issue.update!(pr_review_phase: "draft", draft_review_count: 2)
      agent_run.update!(
        count_toward_draft_review_round: true,
        expected_draft_review_count: 2
      )
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)

      expect(agent_run).to receive(:complete!).ordered.and_wrap_original do |method, **kwargs|
        # Draft round must NOT yet be recorded at this point
        expect(issue.reload.draft_review_count).to eq(2)
        method.call(**kwargs)
      end

      activity.execute(agent_run_id: agent_run.id)
      expect(issue.reload.draft_review_count).to eq(3)
    end

    it "handles comment failure gracefully" do
      enable_summary_comments
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

    it "does not increment draft_review_count when completion fails" do
      issue.update!(pr_review_phase: "draft", draft_review_count: 2)
      agent_run.update!(
        count_toward_draft_review_round: true,
        expected_draft_review_count: 2
      )
      allow(AgentRun).to receive(:find).with(agent_run.id).and_return(agent_run)
      allow(agent_run).to receive(:complete!).and_raise(ActiveRecord::ConnectionTimeoutError)

      expect {
        activity.execute(agent_run_id: agent_run.id)
      }.to raise_error(ActiveRecord::ConnectionTimeoutError)

      expect(issue.reload.draft_review_count).to eq(2)
    end
  end

  def enable_summary_comments
    project.effective_owner.settings.update!(agent_update_comment_mode: "summary")
    if summary_base_sha.blank?
      agent_run.update!(external_metadata: { "pre_run_head_sha" => "fedcba9876543210012345678901234567890abc" })
    end

    base_sha = agent_run.reload.external_metadata["pre_run_head_sha"]
    allow(github_client).to receive(:compare_summary)
      .with(project.full_name, base_sha, agent_run.result_commit_sha)
      .and_return(summary_comparison)
    allow(AgentHarness).to receive(:send_message).and_return(summary_response)
  end
end
