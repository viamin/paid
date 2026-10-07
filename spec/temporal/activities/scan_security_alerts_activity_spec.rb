# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ScanSecurityAlertsActivity do
  let(:activity) { described_class.new }
  let(:project) do
    create(:project,
      auto_scan_security: true,
      security_alert_types: %w[code_scanning],
      code_scanning_interval_hours: 72)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:code_scanning_analyses).and_return([])
  end

  describe "#execute" do
    context "when project is missing" do
      it "returns empty result with project_missing flag" do
        result = activity.execute(project_id: -1)

        expect(result).to eq(alerts_to_fix: [], project_missing: true)
      end
    end

    context "when auto_scan_security is disabled" do
      before { project.update!(auto_scan_security: false) }

      it "returns empty result" do
        result = activity.execute(project_id: project.id)

        expect(result).to eq(alerts_to_fix: [])
      end

      it "resolves code-scanning blocker notifications" do # @spec EAGER-QUEUE-016
        publish_code_scanning_blocker_notifications

        activity.execute(project_id: project.id)

        expect(active_code_scanning_blocker_notifications).to be_empty
      end
    end

    context "when auto_scan_security is disabled but a PR activation is present" do
      before do
        project.update!(auto_scan_security: false)
        allow(Automation::FeatureActivation).to receive(:any_pull_request_feature_enabled?)
          .with(project:, feature: "auto_scan_security").and_return(true)
        allow(github_client).to receive(:code_scanning_alerts).and_return([])
      end

      it "still scans" do
        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:code_scanning_alerts)
      end
    end

    context "with interval gating" do
      before { allow(github_client).to receive(:code_scanning_alerts).and_return([]) }

      it "scans when last_code_scanning_scan_at is nil" do
        project.update_column(:last_code_scanning_scan_at, nil)

        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:code_scanning_alerts)
      end

      it "scans when interval has elapsed" do
        project.update_column(:last_code_scanning_scan_at, 73.hours.ago)

        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:code_scanning_alerts)
      end

      it "skips scan when interval has not elapsed" do
        project.update_column(:last_code_scanning_scan_at, 1.hour.ago)

        activity.execute(project_id: project.id)

        expect(github_client).not_to have_received(:code_scanning_alerts)
      end
    end

    context "when code scanning is disabled for the project" do
      it "resolves code-scanning blocker notifications" do # @spec EAGER-QUEUE-016
        publish_code_scanning_blocker_notifications
        project.update_column(:security_alert_types, [])

        activity.execute(project_id: project.id)

        expect(active_code_scanning_blocker_notifications).to be_empty
      end
    end

    context "with graceful 403/404 handling" do
      before { project.update_column(:last_code_scanning_scan_at, nil) }

      it "handles 404 gracefully and updates last_code_scanning_scan_at" do
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::NotFoundError.new("Not found"))

        expect { activity.execute(project_id: project.id) }.not_to raise_error

        project.reload
        expect(project.last_code_scanning_scan_at).to be_present
      end

      it "raises CodeScanningPermissionsError on 403 without advancing last_code_scanning_scan_at" do
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::ApiError.new("Forbidden", status: 403))

        expect { activity.execute(project_id: project.id) }
          .to raise_error(Temporalio::Error::ApplicationError) do |e|
            expect(e.type).to eq("CodeScanningPermissionsError")
            expect(e.message).to include("security_events")
          end

        project.reload
        expect(project.last_code_scanning_scan_at).to be_nil
      end

      it "records code_scanning_permission_error_at on 403 so subsequent cycles back off" do
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::ApiError.new("Forbidden", status: 403))

        expect { activity.execute(project_id: project.id) }.to raise_error(Temporalio::Error::ApplicationError)

        expect(project.reload.code_scanning_permission_error_at).to be_present
      end

      it "publishes a blocking permission notification when GitHub rejects the scan" do # @spec EAGER-QUEUE-016
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::ApiError.new("Forbidden", status: 403))

        expect { activity.execute(project_id: project.id) }.to raise_error(Temporalio::Error::ApplicationError)

        expect(Notification.active.find_by(source: "code_scanning_permissions_error", subject: project))
          .to have_attributes(severity: "error", blocking: true)
      end

      it "re-raises non-403 ApiError without updating last_code_scanning_scan_at" do
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::ApiError.new("Server error", status: 500))

        expect { activity.execute(project_id: project.id) }.to raise_error(GithubClient::ApiError)

        project.reload
        expect(project.last_code_scanning_scan_at).to be_nil
      end

      it "does not record permission backoff for non-permission configuration errors" do
        project.update_column(:allowed_github_usernames, [])
        allow(github_client).to receive(:code_scanning_alerts).and_return([
          {
            number: 42, state: "open", severity: "high",
            rule_id: "test/rule", rule_description: "Test",
            tool_name: "CodeQL", summary: "Test alert",
            html_url: "https://github.com/o/r/security/code-scanning/42",
            created_at: 1.day.ago.iso8601, updated_at: 1.hour.ago.iso8601
          }
        ])

        expect { activity.execute(project_id: project.id) }
          .to raise_error(Temporalio::Error::ApplicationError) do |e|
            expect(e.type).to eq("ConfigurationError")
          end

        expect(project.reload.code_scanning_permission_error_at).to be_nil
      end

      it "publishes a blocking configuration notification when trusted users are missing" do # @spec EAGER-QUEUE-016
        project.update_column(:allowed_github_usernames, [])
        allow(github_client).to receive(:code_scanning_alerts).and_return([
          {
            number: 42, state: "open", severity: "high",
            rule_id: "test/rule", rule_description: "Test",
            tool_name: "CodeQL", summary: "Test alert",
            html_url: "https://github.com/o/r/security/code-scanning/42",
            created_at: 1.day.ago.iso8601, updated_at: 1.hour.ago.iso8601
          }
        ])

        expect { activity.execute(project_id: project.id) }.to raise_error(Temporalio::Error::ApplicationError)

        expect(Notification.active.find_by(source: "code_scanning_configuration_error", subject: project))
          .to have_attributes(severity: "error", blocking: true)
      end
    end

    context "with a recorded permission error" do
      before { project.update_column(:last_code_scanning_scan_at, nil) }

      it "skips the scan entirely while within the backoff window" do
        allow(github_client).to receive(:code_scanning_alerts)
        project.update_column(:code_scanning_permission_error_at, 5.minutes.ago)

        activity.execute(project_id: project.id)

        expect(github_client).not_to have_received(:code_scanning_alerts)
      end

      it "retries once the backoff window has elapsed" do
        project.update_column(:code_scanning_permission_error_at, 2.hours.ago)
        allow(github_client).to receive(:code_scanning_alerts).and_return([])

        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:code_scanning_alerts)
      end

      it "clears the flag once a scan succeeds again" do
        project.update_column(:code_scanning_permission_error_at, 2.hours.ago)
        allow(github_client).to receive(:code_scanning_alerts).and_return([])

        activity.execute(project_id: project.id)

        expect(project.reload.code_scanning_permission_error_at).to be_nil
      end
    end

    context "with reconciliation of stale synthetic issues" do
      let(:id_offset) { Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET }
      let(:number_offset) { SecurityAlerts::ProcessCodeScanningAlerts::SYNTHETIC_NUMBER_OFFSET }

      before { project.update_column(:last_code_scanning_scan_at, nil) }

      it "closes synthetic issues whose alerts are no longer open" do
        issue = create(:issue,
          project: project,
          source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
          github_issue_id: id_offset + 42,
          github_number: number_offset + 42,
          github_state: "open",
          paid_state: "new")

        # API returns no open alerts — alert #42 was resolved upstream
        allow(github_client).to receive(:code_scanning_alerts).and_return([])

        activity.execute(project_id: project.id)

        issue.reload
        expect(issue.github_state).to eq("closed")
        expect(issue.paid_state).to eq("completed")
      end

      it "skips closure when an issue has an active agent run" do
        issue = create(:issue,
          project: project,
          source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
          github_issue_id: id_offset + 42,
          github_number: number_offset + 42,
          github_state: "open",
          paid_state: "in_progress")
        create(:agent_run, :running, project: project, issue: issue)

        # Alert resolved upstream, but issue has an active run
        allow(github_client).to receive(:code_scanning_alerts).and_return([])

        activity.execute(project_id: project.id)

        issue.reload
        expect(issue.github_state).to eq("open")
        expect(issue.paid_state).to eq("in_progress")
      end

      it "preserves paid_state 'failed' when closing resolved alerts" do
        issue = create(:issue,
          project: project,
          source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
          github_issue_id: id_offset + 42,
          github_number: number_offset + 42,
          github_state: "open",
          paid_state: "failed")

        allow(github_client).to receive(:code_scanning_alerts).and_return([])

        activity.execute(project_id: project.id)

        issue.reload
        expect(issue.github_state).to eq("closed")
        expect(issue.paid_state).to eq("failed")
      end

      it "keeps synthetic issues open when their alert is still open" do
        issue = create(:issue,
          project: project,
          source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
          github_issue_id: id_offset + 42,
          github_number: number_offset + 42,
          github_state: "open",
          paid_state: "new")

        open_alert = {
          number: 42, state: "open", severity: "high",
          rule_id: "test/rule", rule_description: "Test",
          tool_name: "CodeQL", summary: "Test alert",
          html_url: "https://github.com/o/r/security/code-scanning/42",
          created_at: 1.day.ago.iso8601, updated_at: 1.hour.ago.iso8601
        }
        allow(github_client).to receive(:code_scanning_alerts).and_return([ open_alert ])

        activity.execute(project_id: project.id)

        issue.reload
        expect(issue.github_state).to eq("open")
      end
    end

    it "resolves a verification-blocked notification after verification clears the attempt" do # @spec EAGER-QUEUE-016
      project.update_column(:last_code_scanning_scan_at, nil)
      issue = create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
        github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 42)
      attempt = create(:code_scanning_remediation_attempt, issue: issue, status: "verification_blocked",
        merge_commit_sha: "merge", tool_name: "CodeQL", category: "/language:ruby")
      Notifications::Rules::CodeScanningVerificationBlocked.call(scope: [ attempt ])
      analysis = {
        id: "analysis", status: "succeeded", ref: "main", commit_sha: "descendant",
        tool_name: "CodeQL", category: "/language:ruby"
      }
      allow(github_client).to receive(:code_scanning_alerts).and_return([])
      allow(github_client).to receive(:code_scanning_analyses).with(project.full_name).and_return([ analysis ])
      allow(github_client).to receive(:compare).with(project.full_name, "merge", "descendant")
        .and_return(Struct.new(:status).new("identical"))

      activity.execute(project_id: project.id)

      expect(attempt.reload.status).to eq("verified_fixed")
      expect(Notification.active.find_by(source: "code_scanning_verification_blocked", subject: attempt)).to be_nil
    end

    it "publishes the successful scan timestamp with a verification-blocked notification" do # @spec EAGER-QUEUE-016
      project.update_column(:last_code_scanning_scan_at, nil)
      issue = create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
        github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 42)
      attempt = create(:code_scanning_remediation_attempt, issue: issue, status: "verification_blocked",
        merge_commit_sha: "merge", tool_name: "CodeQL", category: "/language:ruby")
      allow(github_client).to receive(:code_scanning_alerts).and_return([
        { number: 42, state: "open", severity: "high", rule_id: "test/rule", rule_description: "Test",
          tool_name: "CodeQL", summary: "Test alert", html_url: "https://github.com/o/r/security/code-scanning/42",
          created_at: 1.day.ago.iso8601, updated_at: 1.hour.ago.iso8601 }
      ])

      activity.execute(project_id: project.id)

      notification = Notification.find_by!(source: "code_scanning_verification_blocked", subject: attempt)
      expect(notification.metadata["last_successful_scan_at"]).to eq(project.reload.last_code_scanning_scan_at.iso8601)
    end
  end

  def publish_code_scanning_blocker_notifications
    issue = create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    attempt = create(:code_scanning_remediation_attempt, issue:, status: "verification_blocked")
    Notifications::Rules::CodeScanningVerificationBlocked.call(scope: [ attempt ])

    project.update_columns(code_scanning_permission_error_at: Time.current, allowed_github_usernames: [])
    Notifications::Rules::CodeScanningPermissionsError.call(scope: [ project ])
    Notifications::Rules::CodeScanningConfigurationError.call(scope: [ project ])
  end

  def active_code_scanning_blocker_notifications
    Notification.active
      .where(account: project.account, source: Activities::ScanSecurityAlertsActivity::CODE_SCANNING_NOTIFICATION_SOURCES)
      .where("metadata ->> 'project_id' = ?", project.id.to_s)
  end
end
