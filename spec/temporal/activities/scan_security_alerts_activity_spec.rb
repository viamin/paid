# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ScanSecurityAlertsActivity do
  let(:activity) { described_class.new }
  let(:project) do
    create(:project,
      auto_scan_security: true,
      security_alert_types: %w[dependabot code_scanning],
      code_scanning_interval_hours: 72)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive_messages(
      code_scanning_analyses: [],
      code_scanning_alert_dispositions: [],
      dependabot_alerts: []
    )
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

      # @spec GITHUB-SYNC-018
      it "returns empty result and leaves coverage visibly disabled" do
        result = activity.execute(project_id: project.id)

        expect(result).to eq(alerts_to_fix: [])
        expect(project.code_scanning_coverage_status).to eq("disabled")
      end

      # @spec DEPENDABOT-COVERAGE-001
      it "resolves the dependabot ingestion notification" do
        publish_dependabot_ingestion_notification

        activity.execute(project_id: project.id)

        expect(Notification.active.find_by(source: "dependabot_alert_coverage_ingestion", subject: project)).to be_nil
      end
    end

    context "when code scanning is not configured" do
      before do
        project.update!(security_alert_types: [ "dependabot" ])
        allow(github_client).to receive(:code_scanning_alerts)
      end

      # @spec GITHUB-SYNC-018
      it "does not fetch and exposes a not-configured coverage state" do
        activity.execute(project_id: project.id)

        expect(github_client).not_to have_received(:code_scanning_alerts)
        expect(project.code_scanning_coverage_status).to eq("not_configured")
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

        expect(github_client).to have_received(:code_scanning_alerts).once
        expect(github_client).to have_received(:code_scanning_alert_dispositions)
          .with(project.full_name, state: "fixed").once
        expect(github_client).to have_received(:code_scanning_alert_dispositions)
          .with(project.full_name, state: "dismissed").once
      end
    end

    context "with interval gating" do
      before { allow(github_client).to receive(:code_scanning_alerts).and_return([]) }

      it "scans when last_code_scanning_scan_at is nil" do
        project.update_column(:last_code_scanning_scan_at, nil)

        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:code_scanning_alerts).once
      end

      it "scans when interval has elapsed" do
        project.update_column(:last_code_scanning_scan_at, 73.hours.ago)

        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:code_scanning_alerts).once
      end

      it "skips scan when interval has not elapsed" do
        project.update_column(:last_code_scanning_scan_at, 1.hour.ago)

        activity.execute(project_id: project.id)

        expect(github_client).not_to have_received(:code_scanning_alerts)
      end

      # @spec GITHUB-SYNC-018
      it "checks blocked remediation verification hourly instead of waiting for discovery cadence" do # @spec EAGER-QUEUE-014
        project.update_column(:last_code_scanning_scan_at, 2.hours.ago)
        issue = create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
        create(:code_scanning_remediation_attempt, issue: issue, status: "verification_blocked")

        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:code_scanning_alerts)
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

      # @spec GITHUB-SYNC-018
      it "records unavailable coverage for 404 without advancing the successful scan" do
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::NotFoundError.new("Not found"))

        expect { activity.execute(project_id: project.id) }.not_to raise_error

        project.reload
        expect(project.last_code_scanning_scan_at).to be_nil
        expect(project.last_code_scanning_scan_attempted_at).to be_present
        expect(project.code_scanning_scan_error_kind).to eq("not_configured")
        expect(project.next_code_scanning_scan_at).to be_within(1.second).of(1.hour.from_now)
      end

      # @spec GITHUB-SYNC-018
      it "redacts secrets from an unavailable coverage reason before persistence" do
        token = "github_pat_#{"a" * 22}"
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::NotFoundError.new("GitHub rejected #{token}"))

        activity.execute(project_id: project.id)

        reason = project.reload.code_scanning_scan_error_reason
        expect(reason).to include("[REDACTED:github_token]")
        expect(reason).not_to include(token)
      end

      # @spec DEPENDABOT-COVERAGE-001 GITHUB-SYNC-018
      it "reconciles Dependabot and retains an ambiguous 403 as a permission error" do
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::ApiError.new("Forbidden", status: 403))

        expect { activity.execute(project_id: project.id) }
          .to raise_error(Temporalio::Error::ApplicationError) do |e|
            expect(e.type).to eq("CodeScanningPermissionsError")
            expect(e.message).to include("security_events")
          end

        project.reload
        expect(project.last_code_scanning_scan_at).to be_nil
        expect(github_client).to have_received(:dependabot_alerts)
        expect(project.code_scanning_scan_error_kind).to eq("permission")
        expect(project.next_code_scanning_scan_at).to be_within(1.second).of(1.hour.from_now)
      end

      # @spec GITHUB-SYNC-020 EAGER-QUEUE-016
      it "disables only code scanning and resolves stale permission notifications when GitHub says scanning is disabled" do
        project.update!(security_alert_types: %w[dependabot code_scanning])
        publish_code_scanning_blocker_notifications
        project.update_columns(code_scanning_permission_error_at: 2.hours.ago)
        allow(github_client).to receive(:code_scanning_alerts).and_raise(
          GithubClient::ApiError.new("Code scanning is not enabled for this repository.", status: 403)
        )

        expect { activity.execute(project_id: project.id) }.not_to raise_error

        expect(project.reload.security_alert_types).to eq([ "dependabot" ])
        expect(project.code_scanning_scan_error_kind).to eq("unavailable")
        expect(active_code_scanning_blocker_notifications).to be_empty
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

      it "records a transient retry for 5xx without updating last_code_scanning_scan_at" do
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::ApiError.new("Server error", status: 500))

        expect { activity.execute(project_id: project.id) }.to raise_error(GithubClient::ApiError)

        project.reload
        expect(project.last_code_scanning_scan_at).to be_nil
        expect(project.code_scanning_scan_error_kind).to eq("transient")
        expect(project.next_code_scanning_scan_at).to be_within(1.second).of(5.minutes.from_now)
      end

      it "records GitHub's rate-limit reset as the next retry" do
        reset_at = 30.minutes.from_now
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::RateLimitError.new(reset_at))

        expect { activity.execute(project_id: project.id) }
          .to raise_error(Temporalio::Error::ApplicationError) { |error| expect(error.type).to eq("RateLimit") }

        project.reload
        expect(project.last_code_scanning_scan_at).to be_nil
        expect(project.code_scanning_scan_error_kind).to eq("rate_limited")
        expect(project.next_code_scanning_scan_at).to be_within(1.second).of(reset_at)
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

    context "when Dependabot alert ingestion fails" do
      before do
        allow(Notifications::Publish).to receive(:call)
        allow(github_client).to receive(:code_scanning_alerts).and_return([])
        allow(github_client).to receive(:dependabot_alerts)
          .and_raise(GithubClient::ApiError.new("Server error", status: 500))
      end

      # @spec DEPENDABOT-COVERAGE-001
      it "surfaces the failed fetch as a blocking coverage failure" do
        expect { activity.execute(project_id: project.id) }.not_to raise_error

        expect(Notifications::Publish).to have_received(:call).with(
          hash_including(blocking: true, severity: :error, metadata: hash_including(reason: "fetch_failed"))
        )
      end

      # @spec DEPENDABOT-COVERAGE-001
      it "still scans CodeQL even when the Dependabot fetch fails" do
        expect { activity.execute(project_id: project.id) }.not_to raise_error

        expect(github_client).to have_received(:code_scanning_alerts)
        project.reload
        expect(project.last_code_scanning_scan_at).to be_present
        expect(project.dependabot_fetch_error_at).to be_present
        expect(project.dependabot_permission_error_at).to be_nil
      end

      # @spec DEPENDABOT-COVERAGE-001
      it "arms the one-hour fetch-failure backoff so subsequent polls skip Dependabot" do
        expect { activity.execute(project_id: project.id) }.not_to raise_error

        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:dependabot_alerts).once
      end

      # @spec DEPENDABOT-COVERAGE-001
      it "converts a Dependabot permission failure to a non-retryable activity error" do
        allow(github_client).to receive(:dependabot_alerts)
          .and_raise(GithubClient::ApiError.new("Forbidden", status: 403))

        expect { activity.execute(project_id: project.id) }
          .to raise_error(Temporalio::Error::ApplicationError) do |error|
            expect(error.type).to eq("DependabotPermissionsError")
          end
      end
    end

    context "when a Dependabot ingestion failure recovers" do
      before { allow(github_client).to receive(:code_scanning_alerts).and_return([]) }

      # @spec DEPENDABOT-COVERAGE-001
      it "resolves the blocking ingestion notification after a successful scan" do
        allow(github_client).to receive(:dependabot_alerts)
          .and_raise(GithubClient::ApiError.new("Server error", status: 500))
        activity.execute(project_id: project.id)
        notification = Notification.active.find_by!(source: "dependabot_alert_coverage_ingestion", subject: project)
        expect(notification).to have_attributes(severity: "error", blocking: true)

        allow(github_client).to receive(:dependabot_alerts).and_return([])
        travel 2.hours do
          activity.execute(project_id: project.id)
        end

        expect(notification.reload.resolved_at).to be_present
        expect(Notification.active.find_by(source: "dependabot_alert_coverage_ingestion", subject: project)).to be_nil
      end

      # @spec DEPENDABOT-COVERAGE-001
      it "resolves the blocking ingestion notification after a permission failure is repaired" do
        allow(github_client).to receive(:dependabot_alerts)
          .and_raise(GithubClient::ApiError.new("Forbidden", status: 403))
        expect { activity.execute(project_id: project.id) }.to raise_error(Temporalio::Error::ApplicationError)
        expect(Notification.active.find_by!(source: "dependabot_alert_coverage_ingestion", subject: project))
          .to have_attributes(severity: "error", blocking: true)

        allow(github_client).to receive(:dependabot_alerts).and_return([])
        travel 2.hours do
          activity.execute(project_id: project.id)
        end

        expect(Notification.active.find_by(source: "dependabot_alert_coverage_ingestion", subject: project)).to be_nil
      end
    end

    context "with Dependabot interval and permission-error backoff" do
      before { project.update_columns(last_code_scanning_scan_at: Time.current, last_dependabot_scan_at: nil) }

      # @spec DEPENDABOT-COVERAGE-001
      it "does not scan Dependabot when the alert type is disabled" do
        project.update_column(:security_alert_types, %w[code_scanning])

        activity.execute(project_id: project.id)

        expect(github_client).not_to have_received(:dependabot_alerts)
      end

      # @spec DEPENDABOT-COVERAGE-001
      it "resolves the ingestion notification when the Dependabot alert type is disabled" do
        publish_dependabot_ingestion_notification
        project.update_column(:security_alert_types, %w[code_scanning])

        activity.execute(project_id: project.id)

        expect(Notification.active.find_by(source: "dependabot_alert_coverage_ingestion", subject: project)).to be_nil
      end

      # @spec DEPENDABOT-COVERAGE-001
      it "skips Dependabot scans until the configured interval has elapsed" do
        project.update_column(:last_dependabot_scan_at, 1.hour.ago)

        activity.execute(project_id: project.id)

        expect(github_client).not_to have_received(:dependabot_alerts)
      end

      # @spec DEPENDABOT-COVERAGE-001
      it "backs off permission failures without re-arming the blocking notification" do
        allow(Notifications::Publish).to receive(:call)
        allow(github_client).to receive(:dependabot_alerts)
          .and_raise(GithubClient::ApiError.new("Forbidden", status: 403))

        expect { activity.execute(project_id: project.id) }.to raise_error(Temporalio::Error::ApplicationError)

        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:dependabot_alerts).once
        expect(Notifications::Publish).to have_received(:call).once
        expect(project.reload.dependabot_permission_error_at).to be_present
      end

      # @spec DEPENDABOT-COVERAGE-001
      it "clears the permission backoff after a successful Dependabot scan" do
        project.update_column(:dependabot_permission_error_at, 2.hours.ago)

        activity.execute(project_id: project.id)

        expect(project.reload).to have_attributes(
          last_dependabot_scan_at: be_present,
          dependabot_permission_error_at: nil
        )
      end

      # @spec DEPENDABOT-COVERAGE-001
      it "clears the fetch-failure backoff after a successful Dependabot scan" do
        project.update_column(:dependabot_fetch_error_at, 2.hours.ago)

        activity.execute(project_id: project.id)

        expect(project.reload).to have_attributes(
          last_dependabot_scan_at: be_present,
          dependabot_fetch_error_at: nil
        )
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

        expect(github_client).to have_received(:code_scanning_alerts).once
      end

      it "clears the flag once a scan succeeds again" do
        project.update_column(:code_scanning_permission_error_at, 2.hours.ago)
        allow(github_client).to receive(:code_scanning_alerts).and_return([])

        activity.execute(project_id: project.id)

        project.reload
        expect(project.code_scanning_permission_error_at).to be_nil
        expect(project.code_scanning_scan_error_kind).to be_nil
        expect(project.next_code_scanning_scan_at).to be_nil
      end
    end

    context "with a zero-alert response" do
      # @spec GITHUB-SYNC-018
      it "records a successful complete snapshot and clears prior failure coverage" do
        project.update_columns(code_scanning_scan_error_kind: "transient", code_scanning_scan_error_reason: "Timeout",
          next_code_scanning_scan_at: 1.minute.ago)
        allow(github_client).to receive(:code_scanning_alerts).and_return([])

        activity.execute(project_id: project.id)

        project.reload
        expect(project.last_code_scanning_scan_at).to be_present
        expect(project.last_code_scanning_scan_attempted_at).to be_present
        expect(project.code_scanning_scan_error_kind).to be_nil
        expect(project.next_code_scanning_scan_at).to be_nil
      end
    end

    context "with a recorded fetch failure" do
      before { project.update_columns(last_code_scanning_scan_at: nil, last_dependabot_scan_at: nil) }

      it "skips the Dependabot scan while within the fetch-failure backoff window" do
        project.update_column(:dependabot_fetch_error_at, 5.minutes.ago)
        allow(github_client).to receive_messages(code_scanning_alerts: [], dependabot_alerts: [])

        activity.execute(project_id: project.id)

        expect(github_client).not_to have_received(:dependabot_alerts)
      end

      it "retries Dependabot once the fetch-failure backoff window has elapsed" do
        project.update_column(:dependabot_fetch_error_at, 2.hours.ago)
        allow(github_client).to receive_messages(code_scanning_alerts: [], dependabot_alerts: [])

        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:dependabot_alerts)
      end
    end

    context "with reconciliation of stale synthetic issues" do
      let(:id_offset) { Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET }
      let(:number_offset) { SecurityAlerts::ProcessCodeScanningAlerts::SYNTHETIC_NUMBER_OFFSET }

      before { project.update_column(:last_code_scanning_scan_at, nil) }

      it "retains synthetic issues when an empty snapshot has no explicit disposition" do
        issue = create(:issue,
          project: project,
          source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
          github_issue_id: id_offset + 42,
          github_number: number_offset + 42,
          github_state: "open",
          paid_state: "new")

        # An all-empty response does not identify alert #42's disposition.
        allow(github_client).to receive(:code_scanning_alerts).and_return([])

        activity.execute(project_id: project.id)

        issue.reload
        expect(issue.github_state).to eq("open")
        expect(issue.paid_state).to eq("new")
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

      it "preserves paid_state 'failed' when an alert is absent without disposition" do
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
        expect(issue.github_state).to eq("open")
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

  def publish_dependabot_ingestion_notification
    Notifications::Publish.call(
      account: project.account, source: "dependabot_alert_coverage_ingestion", subject: project,
      severity: :error, blocking: true, nav_section: "projects",
      title: "Dependabot alert coverage is unavailable", description: "Server error",
      metadata: { project_id: project.id, reason: "fetch_failed" }
    )
  end

  def active_code_scanning_blocker_notifications
    Notification.active
      .where(account: project.account, source: Activities::ScanSecurityAlertsActivity::CODE_SCANNING_NOTIFICATION_SOURCES)
      .where("metadata ->> 'project_id' = ?", project.id.to_s)
  end
end
