# frozen_string_literal: true

require "rails_helper"

RSpec.describe AutoMergeAttempt do
  # @spec AUTO-MERGE-004
  describe "project scoping" do
    it "requires the issue to belong to the same project" do
      attempt = build(:auto_merge_attempt, project: create(:project), issue: create(:issue, :pull_request))

      expect(attempt).not_to be_valid
      expect(attempt.errors[:issue]).to include("must belong to the same project")
    end
  end

  describe AutoMergeAttempts::Record do
    # @spec AUTO-MERGE-004
    it "sanitizes secret material before persistence" do
      issue = create(:issue, :pull_request)
      raw_token = "ghp_#{"1" * 36}"

      attempt = described_class.call(
        project: issue.project,
        issue: issue,
        actor_path: AutoMergeAttempts::Record::ACTOR_REVIEW_AUTO_MERGE,
        status: "blocked",
        reason_code: AutoMergeAttempts::Record::REASON_MISSING_WORKFLOWS_PERMISSION,
        message: "refusing to allow #{raw_token} without workflows permission",
        credential_mode: "github_app"
      )

      expect(attempt.sanitized_message).to include("[REDACTED:github_token]")
      expect(attempt.sanitized_message).not_to include(raw_token)
    end

    # @spec AUTO-MERGE-004
    it "strips raw stack traces from persisted messages" do
      issue = create(:issue, :pull_request)
      message = <<~TEXT
        merge request failed
        from /workspace/app/services/github_client.rb:42:in `merge_pull_request'
        /workspace/lib/octokit/connection.rb:17:in `request'
      TEXT

      attempt = described_class.call(
        project: issue.project,
        issue: issue,
        actor_path: AutoMergeAttempts::Record::ACTOR_DEPENDABOT_AUTO_MERGE,
        status: "failed",
        reason_code: AutoMergeAttempts::Record::REASON_EXPECTED_MERGE_FAILURE,
        message: message,
        credential_mode: "pat"
      )

      expect(attempt.sanitized_message).to eq("merge request failed")
    end

    # @spec AUTO-MERGE-004
    it "deduplicates consecutive identical skip outcomes for the same issue" do
      issue = create(:issue, :pull_request)
      first = duplicate_skip_attempt(issue)
      second = duplicate_skip_attempt(issue)

      expect(second).to eq(first)
      expect(issue.auto_merge_attempts.count).to eq(1)
    end

    def duplicate_skip_attempt(issue)
      described_class.call(
        project: issue.project,
        issue: issue,
        actor_path: AutoMergeAttempts::Record::ACTOR_DEPENDABOT_AUTO_MERGE,
        status: "skipped",
        reason_code: AutoMergeAttempts::Record::REASON_CHECKS_NOT_GREEN,
        message: "Required checks are not green yet.",
        credential_mode: "pat"
      )
    end
  end

  # @spec AUTO-MERGE-004
  describe "tenant row-level scoping", :tenant_isolation do
    around do |example|
      skip "requires CREATE ROLE privilege for RLS policy checks" unless can_manage_roles?

      setup_restricted_role
      example.run
    ensure
      ActiveRecord::Base.connection.execute("RESET ROLE")
      cleanup_restricted_role
    end

    it "only exposes attempts for the current account" do
      account_a = TenantContext.with_system_access { create(:account) }
      account_b = TenantContext.with_system_access { create(:account) }
      attempt_a = TenantContext.with_system_access do
        issue = create(:issue, :pull_request, project: create(:project, account: account_a))
        create(:auto_merge_attempt, project: issue.project, issue: issue)
      end
      TenantContext.with_system_access do
        issue = create(:issue, :pull_request, project: create(:project, account: account_b))
        create(:auto_merge_attempt, project: issue.project, issue: issue)
      end

      as_restricted_role do
        TenantContext.with(account_a) do
          expect(described_class.all).to contain_exactly(attempt_a)
        end
      end
    end

    private

    def setup_restricted_role
      cleanup_restricted_role
      connection = ActiveRecord::Base.connection
      connection.execute("CREATE ROLE paid_rls_spec NOLOGIN")
      connection.execute("GRANT USAGE ON SCHEMA public TO paid_rls_spec")
      connection.execute("GRANT SELECT ON ALL TABLES IN SCHEMA public TO paid_rls_spec")
      connection.execute("GRANT paid_rls_spec TO current_user")
    end

    def as_restricted_role
      ActiveRecord::Base.connection.execute("SET ROLE paid_rls_spec")
      yield
    ensure
      ActiveRecord::Base.connection.execute("RESET ROLE")
    end

    def cleanup_restricted_role
      return unless ActiveRecord::Base.connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = 'paid_rls_spec'")

      connection = ActiveRecord::Base.connection
      connection.execute("GRANT paid_rls_spec TO current_user")
      connection.execute("DROP OWNED BY paid_rls_spec")
      connection.execute("DROP ROLE IF EXISTS paid_rls_spec")
    end

    def can_manage_roles?
      ActiveModel::Type::Boolean.new.cast(
        ActiveRecord::Base.connection.select_value("SELECT rolcreaterole FROM pg_roles WHERE rolname = current_user")
      )
    end
  end
end
