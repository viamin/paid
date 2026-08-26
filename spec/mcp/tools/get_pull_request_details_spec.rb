# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Tools::GetPullRequestDetails do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account, auto_merge_mode: "all") }
  let(:pr) { create(:issue, :pull_request, project: project) }
  let(:github_client) { instance_double(GithubClient) }
  let(:pull_request_data) do
    OpenStruct.new(
      number: pr.github_number,
      mergeable: true,
      merged_at: nil,
      head: OpenStruct.new(sha: "abc123")
    )
  end

  before do
    pr.update!(
      auto_merge_blockers: { "failed" => [], "not_evaluated" => [] },
      auto_merge_evaluated_at: Time.current
    )
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(
      recent_issue_comments: [],
      pull_request_review_comments: [],
      pull_request: pull_request_data,
      check_runs_for_ref: [],
      combined_status: { state: "pending", total_count: 0 }
    )
  end

  describe "#call" do
    # @spec CHAT-API-011
    it "returns PR details with serialized comments and auto-merge diagnostics" do
      comment = Struct.new(:user, :body, :created_at).new(
        Struct.new(:login).new("octocat"),
        "Conversation comment",
        Time.current
      )
      review_comment = {
        user_login: "reviewer",
        body: "Line comment",
        path: "app/models/user.rb",
        created_at: Time.current
      }
      allow(github_client).to receive_messages(
        recent_issue_comments: [ comment ],
        pull_request_review_comments: [ review_comment ]
      )

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect_comment_fetches
      expect_comments(result, comment:, review_comment:)
      expect(result[:auto_merge]).to eq(expected_ready_auto_merge)
    end

    it "returns empty comment arrays when GitHub calls fail" do
      allow(github_client).to receive(:recent_issue_comments).and_raise(StandardError, "API error")
      allow(github_client).to receive(:pull_request_review_comments).and_raise(StandardError, "API error")

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:comments]).to eq([])
      expect(result[:review_comments]).to eq([])
    end

    it "reports a merge-permission rejection with a sanitized message" do
      raw_token = "ghp_#{"1" * 36}"
      record_blocked_attempt(raw_token:)

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to include(
        auto_merge_status: "blocked",
        reason_code: "missing_workflows_permission",
        credential_mode: "pat",
        merge_permission_rejected: true,
        blockers: []
      )
      expect(result[:auto_merge][:last_auto_merge_attempt_at]).to eq(pr.auto_merge_attempts.recent.first.attempted_at)
      expect(result[:auto_merge][:sanitized_message]).to include("[REDACTED:github_token]")
      expect(result[:auto_merge][:sanitized_message]).not_to include(raw_token)
    end

    it "explains a checks-not-green blocker from the persisted snapshot without a prior attempt" do
      persist_auto_merge_snapshot!(checks_not_green_blocker)

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to eq(
        last_auto_merge_attempt_at: nil,
        auto_merge_status: "blocked",
        reason_code: "checks_not_green",
        sanitized_message: "Required checks are not green yet.",
        credential_mode: "personal_access_token",
        merge_permission_rejected: false,
        cooldown_until: nil,
        next_action: "Wait for required checks to pass, then let auto-merge evaluate the pull request again.",
        blockers: [ checks_not_green_blocker ]
      )
    end

    it "reports the latest persisted attempt timestamp alongside ready status" do
      attempt = create(:auto_merge_attempt, project: project, issue: pr, status: "skipped", reason_code: "checks_not_green")

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to eq(expected_auto_merge(
        status: "ready",
        credential_mode: "personal_access_token",
        last_auto_merge_attempt_at: attempt.attempted_at,
        next_action: "Wait for the next automatic merge evaluation or merge this pull request manually."
      ))
    end

    it "reports unavailable diagnostics when no persisted snapshot is available yet" do
      pr.update!(auto_merge_blockers: nil, auto_merge_evaluated_at: nil)

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to include(
        auto_merge_status: "unavailable",
        reason_code: "diagnostics_unavailable",
        sanitized_message: "Auto-merge diagnostics are unavailable until Paid completes a PR scan for this pull request.",
        blockers: []
      )
    end

    it "explains a not-mergeable blocker from the persisted snapshot without a prior attempt" do
      persist_auto_merge_snapshot!(not_mergeable_blocker)

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to eq(
        last_auto_merge_attempt_at: nil,
        auto_merge_status: "blocked",
        reason_code: "not_mergeable",
        sanitized_message: "GitHub is not reporting this pull request as mergeable yet.",
        credential_mode: "personal_access_token",
        merge_permission_rejected: false,
        cooldown_until: nil,
        next_action: "Resolve merge conflicts or other mergeability blockers, then wait for the next automatic check.",
        blockers: [ not_mergeable_blocker ]
      )
    end

    it "explains a workflow-permission blocker for app-backed projects with PAT fallback" do
      fallback_token = create(:github_token, account: account)
      project.update!(
        github_token: nil,
        github_installation: create(:github_installation, account: account),
        git_push_pat_fallback_enabled: true,
        git_push_fallback_token: fallback_token
      )
      pr.update!(
        merge_permission_rejected_at: Time.current,
        merge_permission_rejection_reason: "refusing to allow a GitHub App to create or update without `workflows` permission"
      )

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to include(
        auto_merge_status: "blocked",
        reason_code: "missing_workflows_permission",
        credential_mode: "github_app_with_pat_fallback",
        merge_permission_rejected: true,
        next_action: "Check the configured PAT fallback credential and the GitHub App permissions, then merge manually or wait for the next automatic check."
      )
    end

    it "reports a PR merged out-of-band as merged even when a stale merge-permission rejection is still persisted" do
      # FetchIssuesActivity#close_stale_pull_requests flips pr_review_phase to
      # "merged" and github_state to "closed" when a PR is merged manually, but
      # does not clear merge_permission_rejected_at. The auto-merge diagnostic
      # must surface the merged state instead of the stale rejection.
      mark_pr_merged_out_of_band(pr)
      stub_merged_pull_request(merged_at: 1.hour.ago)

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to eq(
        last_auto_merge_attempt_at: nil,
        auto_merge_status: "merged",
        reason_code: nil,
        sanitized_message: nil,
        credential_mode: "personal_access_token",
        merge_permission_rejected: false,
        cooldown_until: nil,
        next_action: "No action required.",
        blockers: []
      )
    end

    it "reports merged when GitHub already shows merged_at but the local PR row is still open" do
      pr.update!(
        pr_review_phase: "ready",
        github_state: "open",
        merge_permission_rejected_at: 1.hour.ago,
        merge_permission_rejection_reason: "missing workflows permission",
        auto_merge_blockers: { "failed" => [ not_mergeable_blocker ], "not_evaluated" => [] },
        auto_merge_evaluated_at: Time.current
      )
      stub_merged_pull_request(merged_at: 5.minutes.ago)

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to include(
        auto_merge_status: "merged",
        merge_permission_rejected: false,
        next_action: "No action required.",
        blockers: []
      )
    end

    it "reports a PR merged out-of-band as merged even when live credentials are unavailable" do
      # Even without a usable GitHub credential, persisted pr_review_phase:
      # "merged" is enough to report the merged status — the stale rejection
      # flag must not block this when project.client cannot be built.
      mark_pr_merged_out_of_band(pr)
      installation = create(:github_installation, account: account)
      project.update!(github_token: nil, github_installation: installation)
      # Revoke the installation after the project accepts it so the
      # active-credential guard sees a non-active installation at runtime.
      installation.update!(revoked_at: Time.current)

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to include(
        auto_merge_status: "merged",
        merge_permission_rejected: false,
        next_action: "No action required.",
        blockers: []
      )
    end

    it "reports credentials_unavailable when the app installation is inactive" do
      installation = create(:github_installation, account: account)
      project.update!(github_token: nil, github_installation: installation)
      installation.update!(revoked_at: Time.current)

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to include(
        auto_merge_status: "not_attempted",
        reason_code: "credentials_unavailable",
        credential_mode: "github_app",
        blockers: []
      )
    end

    # @spec CHAT-API-011
    it "returns persisted diagnostics when app installation token minting fails" do
      installation = create(:github_installation, account: account)
      project.update!(github_token: nil, github_installation: installation)
      allow(Github::AppInstallation).to receive(:token_for).and_raise(
        Github::AppInstallation::Error,
        "GitHub App installation request failed (status 401): Bad credentials"
      )

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to eq(expected_ready_auto_merge.merge(credential_mode: "github_app"))
      expect(Github::AppInstallation).to have_received(:token_for).with(
        installation_id: installation.github_installation_id,
        repo_full_name: project.full_name
      )
    end

    # @spec CHAT-API-011
    it "returns persisted diagnostics when the app installation token request times out" do
      installation = create(:github_installation, account: account)
      project.update!(github_token: nil, github_installation: installation)
      allow(Github::AppInstallation).to receive(:token_for).and_raise(
        Faraday::TimeoutError,
        "execution expired"
      )

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to eq(expected_ready_auto_merge.merge(credential_mode: "github_app"))
      expect(Github::AppInstallation).to have_received(:token_for).with(
        installation_id: installation.github_installation_id,
        repo_full_name: project.full_name
      )
    end

    it "reports an inactive (revoked) PAT as credentials_unavailable instead of letting the API call fail" do
      # `Project#client` returns a GithubClient for any present PAT without
      # checking `github_token.active?`, so without an up-front guard a
      # revoked token reaches `pull_request`, raises GithubClient::Error, and
      # would surface as `diagnostics_unavailable`. The diagnostic should
      # report the inactive-credential state up front instead.
      project.github_token.update!(revoked_at: 1.hour.ago)

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to include(
        auto_merge_status: "not_attempted",
        reason_code: "credentials_unavailable",
        credential_mode: "personal_access_token",
        blockers: []
      )
      expect(github_client).not_to have_received(:pull_request)
    end

    it "reports an expired PAT as credentials_unavailable instead of letting the API call fail" do
      project.github_token.update!(expires_at: 1.day.ago)

      result = tool.call(project_id: project.id, issue_id: pr.id)

      expect(result[:auto_merge]).to include(
        auto_merge_status: "not_attempted",
        reason_code: "credentials_unavailable",
        credential_mode: "personal_access_token",
        blockers: []
      )
      expect(github_client).not_to have_received(:pull_request)
    end

    it "raises for pull requests outside the user's account" do
      other_pr = create(:issue, :pull_request)

      expect { tool.call(project_id: other_pr.project_id, issue_id: other_pr.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  def expect_comment_fetches
    expect(github_client).to have_received(:recent_issue_comments).with(project.full_name, pr.github_number)
    expect(github_client).to have_received(:pull_request_review_comments).with(project.full_name, pr.github_number, per_page: 20)
  end

  def expect_comments(result, comment:, review_comment:)
    expect(result[:comments]).to eq([ { user: "octocat", body: "Conversation comment", created_at: comment.created_at } ])
    expect(result[:review_comments]).to eq([ { user: "reviewer", body: "Line comment", path: "app/models/user.rb", created_at: review_comment[:created_at] } ])
  end

  def mark_pr_merged_out_of_band(pr)
    pr.update!(
      github_state: "closed",
      pr_review_phase: "merged",
      merge_permission_rejected_at: 2.hours.ago,
      merge_permission_rejection_reason: "refusing to allow a GitHub App to create or update without `workflows` permission"
    )
  end

  def record_blocked_attempt(raw_token:)
    message = "refusing to allow a GitHub App to create or update #{raw_token} without `workflows` permission"
    AutoMergeAttempts::Record.call(
      project: project,
      issue: pr,
      attempted_at: Time.current,
      actor_path: AutoMergeAttempts::Record::ACTOR_REVIEW_AUTO_MERGE,
      status: "blocked",
      reason_code: AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION,
      message: message,
      credential_mode: "pat"
    )
    pr.update!(
      merge_permission_rejected_at: Time.current,
      merge_permission_rejection_reason: message
    )
  end

  def stub_merged_pull_request(merged_at:)
    allow(github_client).to receive(:pull_request).and_return(
      OpenStruct.new(
        number: pr.github_number,
        mergeable: true,
        merged_at: merged_at,
        head: OpenStruct.new(sha: "abc123")
      )
    )
  end

  def expected_ready_auto_merge
    expected_auto_merge(
      status: "ready",
      next_action: "Wait for the next automatic merge evaluation or merge this pull request manually."
    )
  end

  def expected_auto_merge(status:, reason_code: nil, sanitized_message: nil, credential_mode: "personal_access_token",
    merge_permission_rejected: false, next_action:, last_auto_merge_attempt_at: nil, cooldown_until: nil, blockers: [])
    {
      last_auto_merge_attempt_at:,
      auto_merge_status: status,
      reason_code:,
      sanitized_message:,
      credential_mode:,
      merge_permission_rejected:,
      cooldown_until:,
      next_action:,
      blockers:
    }
  end

  def persist_auto_merge_snapshot!(blocker)
    pr.update!(
      auto_merge_blockers: { "failed" => [ blocker ], "not_evaluated" => [] },
      auto_merge_evaluated_at: Time.current
    )
  end

  def checks_not_green_blocker
    blocker(
      signal: "checks_green",
      status: "failed",
      reason_code: "checks_not_green",
      sanitized_message: "Required checks are not green yet.",
      next_action: "Wait for required checks to pass, then let auto-merge evaluate the pull request again."
    )
  end

  def not_mergeable_blocker
    blocker(
      signal: "mergeable",
      status: "failed",
      reason_code: "not_mergeable",
      sanitized_message: "GitHub is not reporting this pull request as mergeable yet.",
      next_action: "Resolve merge conflicts or other mergeability blockers, then wait for the next automatic check."
    )
  end

  def blocker(signal:, status:, reason_code:, sanitized_message:, next_action:)
    {
      "signal" => signal,
      "status" => status,
      "reason_code" => reason_code,
      "sanitized_message" => sanitized_message,
      "next_action" => next_action
    }
  end
end
