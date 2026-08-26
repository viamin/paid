# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::GithubDiagnostics do
  describe ".call" do
    let(:account) { create(:account) }

    context "with an app-backed project and permission failures" do
      let(:installation) do
        create(
          :github_installation,
          account: account,
          account_login: "acme-org",
          accessible_repositories: [ { "full_name" => "acme/widgets", "id" => 123 } ]
        )
      end
      let(:fallback_token) { create(:github_token, account: account, name: "Workflow Fallback PAT") }
      let(:project) do
        create(
          :project,
          :with_github_installation,
          account: account,
          owner: "acme",
          repo: "widgets",
          github_installation: installation,
          webhook_secret: "super-secret-webhook"
        )
      end
      let(:diagnostics) { described_class.call(project: project) }

      before do
        project.update!(git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback_token)
        create(
          :github_health_state,
          endpoint: GithubHealthState.endpoint_for_github_installation(installation.github_installation_id),
          rate_limit_remaining: 14_500,
          rate_limit_limit: 15_000
        )
        create(
          :github_health_state,
          endpoint: GithubHealthState.endpoint_for_github_token(fallback_token.id),
          circuit_state: "half_open",
          failure_count: 2,
          circuit_opened_at: 10.minutes.ago
        )
        create(
          :auto_merge_attempt,
          project: project,
          issue: create(:issue, :pull_request, project: project),
          attempted_at: 2.hours.ago,
          reason_code: AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION,
          sanitized_message: "GitHub rejected the operation because the App lacks the `workflows` permission required for workflow file changes."
        )
        create(
          :issue,
          project: project,
          runner_retry_abandoned_at: 1.hour.ago,
          runner_retry_abandon_reason: "Push rejected: the GitHub App installation token lacks the `workflows` permission for a push under `.github/workflows/`."
        )
      end

      it "reports app mode, app health, and webhook presence" do # @spec GITHUB-SYNC-009
        expect(diagnostics).to include(credential_mode: "app")
        expect(diagnostics.dig(:github_app, :installation_present)).to be(true)
        expect(diagnostics.dig(:github_app, :status)).to eq("active")
        expect(diagnostics.dig(:github_app, :health)).to eq("available")
        expect(diagnostics.dig(:github_app, :repository_access)).to be(true)
        expect(diagnostics.dig(:webhook, :configured)).to be(true)
      end

      it "reports fallback PAT state using safe token metadata" do # @spec GITHUB-SYNC-009
        expect(diagnostics.dig(:pat_fallback, :configured)).to be(true)
        expect(diagnostics.dig(:pat_fallback, :status)).to eq("active")
        expect(diagnostics.dig(:pat_fallback, :health)).to eq("recovering")
        expect(diagnostics.dig(:pat_fallback, :token)).to eq(
          id: fallback_token.id,
          name: "Workflow Fallback PAT"
        )
      end

      it "sanitizes permission failures and redacts secret material" do # @spec GITHUB-SYNC-009
        expect(diagnostics.fetch(:recent_permission_failures).map { |failure| failure[:code] })
          .to all(eq("missing_workflows_permission"))

        serialized = diagnostics.to_json
        expect(serialized).not_to include(project.webhook_secret)
        expect(serialized).not_to include(fallback_token.token)
        expect(serialized).not_to include("refusing to allow a GitHub App")
      end
    end

    it "recommends configuring the webhook secret before deeper merge investigation" do
      project = create(:project, account: account, webhook_secret: nil)

      expect(described_class.call(project: project).dig(:recommended_action, :code))
        .to eq("configure_project_webhook_secret")
    end

    context "with a revoked PAT fallback and workflow permission blocker" do
      let(:installation) do
        create(
          :github_installation,
          account: account,
          accessible_repositories: [ { "full_name" => "acme/widgets", "id" => 123 } ]
        )
      end
      let(:fallback_token) { create(:github_token, :revoked, account: account, name: "Revoked Fallback") }
      let(:project) do
        create(
          :project,
          :with_github_installation,
          account: account,
          owner: "acme",
          repo: "widgets",
          github_installation: installation,
          webhook_secret: "present"
        )
      end

      before do
        project.update!(git_push_pat_fallback_enabled: true, git_push_fallback_token: fallback_token)
        create(
          :auto_merge_attempt,
          project: project,
          issue: create(:issue, :pull_request, project: project),
          attempted_at: Time.current,
          reason_code: AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION
        )
      end

      it "reports the fallback as revoked and not configured" do
        diagnostics = described_class.call(project: project)

        expect(diagnostics.dig(:pat_fallback, :status)).to eq("revoked")
        expect(diagnostics.dig(:pat_fallback, :configured)).to be(false)
      end

      it "recommends rotating the fallback or granting workflows permission" do
        expect(described_class.call(project: project).dig(:recommended_action, :code))
          .to eq("grant_workflows_permission_or_rotate_pat_fallback")
      end
    end

    it "returns the most recent permission failures by rejection timestamp, not issue update time" do # @spec GITHUB-SYNC-009
      project = create(:project, account: account, webhook_secret: "present")
      older_failure = create_merge_failure(project:, occurred_at: 2.days.ago, updated_at: Time.current)
      newer_failure = create_push_failure(project:, occurred_at: 1.hour.ago, updated_at: 3.days.ago)

      failures = described_class.call(project: project).fetch(:recent_permission_failures)

      expect(failures.first).to include(
        issue_id: newer_failure.id,
        kind: "push",
        occurred_at: newer_failure.runner_retry_abandoned_at
      )
      expect(failures.second).to include(
        issue_id: older_failure.issue_id,
        kind: "merge",
        occurred_at: older_failure.attempted_at
      )
    end

    it "does not let non-permission retry abandonments crowd out push permission failures" do # @spec GITHUB-SYNC-009
      project = create(:project, account: account, webhook_secret: "present")
      permission_failure = create_push_failure(project:, occurred_at: 2.days.ago, updated_at: 2.days.ago)

      (Projects::GithubDiagnostics::RECENT_FAILURE_CANDIDATE_LIMIT + 1).times do |index|
        create(
          :issue,
          project: project,
          runner_retry_abandoned_at: index.minutes.ago,
          runner_retry_abandon_reason: "Retry limit reached after transient failure"
        )
      end

      failures = described_class.call(project: project).fetch(:recent_permission_failures)

      expect(failures).to contain_exactly(
        include(
          issue_id: permission_failure.id,
          kind: "push",
          occurred_at: permission_failure.runner_retry_abandoned_at
        )
      )
    end

    it "does not mutate persisted github health state when reporting endpoint health" do # @spec GITHUB-SYNC-009
      project = create(:project, account: account, webhook_secret: "present")
      state = create(
        :github_health_state,
        endpoint: project.github_health_endpoint,
        circuit_state: "open",
        circuit_opened_at: 10.minutes.ago
      )

      diagnostics = described_class.call(project: project)

      expect(diagnostics.dig(:primary_credential, :health)).to eq("circuit_open")
      expect(state.reload.circuit_state).to eq("open")
    end
  end

  def create_merge_failure(project:, occurred_at:, updated_at:)
    create(:auto_merge_attempt,
      project: project,
      issue: create(:issue, :pull_request, project: project, updated_at: updated_at),
      attempted_at: occurred_at,
      reason_code: AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION,
      updated_at: updated_at)
  end

  def create_push_failure(project:, occurred_at:, updated_at:)
    create(
      :issue,
      project: project,
      runner_retry_abandoned_at: occurred_at,
      runner_retry_abandon_reason: "#{Issue::PUSH_PERMISSION_ABANDON_PREFIX} missing workflows permission",
      updated_at: updated_at
    )
  end
end
