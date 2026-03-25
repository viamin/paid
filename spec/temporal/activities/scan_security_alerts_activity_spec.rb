# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ScanSecurityAlertsActivity do
  let(:activity) { described_class.new }
  let(:id_offset) { Issue::SYNTHETIC_ISSUE_ID_OFFSET }
  let(:source) { Issue::SYNTHETIC_DEPENDABOT_SOURCE }
  let(:project) do
    create(:project,
      auto_scan_security: true,
      security_severity_threshold: "high",
      security_alert_types: [ "dependabot" ],
      max_security_fix_runs: 3)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when project is missing" do
      it "returns empty result with project_missing flag" do
        result = activity.execute(project_id: -1)

        expect(result[:alerts_to_fix]).to eq([])
        expect(result[:project_missing]).to be true
      end
    end

    context "when auto_scan_security is disabled" do
      before { project.update!(auto_scan_security: false) }

      it "returns empty result" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
      end
    end

    context "when there are no open alerts" do
      before do
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return([])
      end

      it "returns empty result" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
      end
    end

    context "when there are open Dependabot alerts" do
      let(:alerts) do
        [
          {
            number: 1,
            state: "open",
            severity: "high",
            package_name: "minimatch",
            package_ecosystem: "npm",
            patched_version: "3.0.5",
            summary: "ReDoS vulnerability in minimatch",
            html_url: "https://github.com/owner/repo/security/dependabot/1"
          },
          {
            number: 2,
            state: "open",
            severity: "critical",
            package_name: "lodash",
            package_ecosystem: "npm",
            patched_version: "4.17.21",
            summary: "Prototype pollution in lodash",
            html_url: "https://github.com/owner/repo/security/dependabot/2"
          }
        ]
      end

      before do
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return(alerts)
      end

      it "creates issues for each alert sorted by severity" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix].size).to eq(2)
        # Critical alert (2) sorts before high alert (1)
        expect(result[:alerts_to_fix].first[:alert_number]).to eq(2)
        expect(result[:alerts_to_fix].first[:alert_type]).to eq("dependabot")
        expect(result[:alerts_to_fix].second[:alert_number]).to eq(1)
      end

      it "creates Issue records with correct attributes" do
        activity.execute(project_id: project.id)

        issue = project.issues.find_by(source: source, github_issue_id: id_offset + 1)
        expect(issue).to be_present
        expect(issue.title).to include("[Security]")
        expect(issue.title).to include("minimatch")
        expect(issue.title).to include("3.0.5")
        expect(issue.title).to include("dependabot-alert-1")
        expect(issue.body).to include("ReDoS vulnerability")
        expect(issue.labels).to include("security")
        expect(issue.paid_state).to eq("new")
        expect(issue.github_state).to eq("open")
        expect(issue.source).to eq(source)
      end

      it "sets a trusted creator login" do
        activity.execute(project_id: project.id)

        issue = project.issues.find_by(source: source, github_issue_id: id_offset + 1)
        expect(issue.trusted?).to be true
      end

      it "assigns deterministic github_numbers derived from alert numbers" do
        activity.execute(project_id: project.id)

        numbers = project.issues.order(:id).pluck(:github_number)
        # SYNTHETIC_NUMBER_OFFSET (100_000_000) + alert[:number]
        expect(numbers).to contain_exactly(100_000_001, 100_000_002)
      end

      it "respects max_security_fix_runs limit" do
        project.update!(max_security_fix_runs: 1)

        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix].size).to eq(1)
      end

      it "prioritizes more severe alerts when capacity is limited" do
        project.update!(max_security_fix_runs: 1)

        result = activity.execute(project_id: project.id)

        # Alert #2 is critical, alert #1 is high — critical should be picked first
        expect(result[:alerts_to_fix].first[:alert_number]).to eq(2)
      end
    end

    context "when an alert already has an existing issue" do
      let(:alerts) do
        [
          {
            number: 1,
            state: "open",
            severity: "high",
            package_name: "minimatch",
            package_ecosystem: "npm",
            patched_version: "3.0.5",
            summary: "ReDoS vulnerability",
            html_url: "https://github.com/owner/repo/security/dependabot/1"
          }
        ]
      end

      before do
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return(alerts)

        # Use the same synthetic github_issue_id that the activity generates
        # (Issue::SYNTHETIC_ISSUE_ID_OFFSET + alert number) so the duplicate check matches.
        create(:issue,
          project: project,
          title: "[Security] Upgrade minimatch — dependabot-alert-1",
          github_issue_id: id_offset + 1,
          github_state: "open",
          source: source)
      end

      it "skips alerts that already have issues" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
      end
    end

    context "when an existing open issue has stale alert metadata" do
      let(:alerts) do
        [
          {
            number: 1,
            state: "open",
            severity: "critical",
            package_name: "minimatch",
            package_ecosystem: "npm",
            patched_version: "5.0.0",
            summary: "Updated advisory for minimatch",
            html_url: "https://github.com/owner/repo/security/dependabot/1"
          }
        ]
      end

      let!(:existing_issue) do
        create(:issue,
          project: project,
          title: "[Security] Upgrade minimatch to 3.0.5 (high) — dependabot-alert-1",
          body: "old body",
          github_issue_id: id_offset + 1,
          github_state: "open",
          source: source)
      end

      before do
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return(alerts)
      end

      it "updates title, body, and github_updated_at without triggering a new agent run" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])

        existing_issue.reload
        expect(existing_issue.title).to include("5.0.0")
        expect(existing_issue.title).to include("critical")
        expect(existing_issue.body).to include("Updated advisory for minimatch")
        expect(existing_issue.github_updated_at).to be_within(5.seconds).of(Time.current)
      end
    end

    context "when a previously closed synthetic issue has its alert re-opened" do
      let(:alerts) do
        [
          {
            number: 1,
            state: "open",
            severity: "high",
            package_name: "minimatch",
            package_ecosystem: "npm",
            patched_version: "3.0.5",
            summary: "ReDoS vulnerability",
            html_url: "https://github.com/owner/repo/security/dependabot/1"
          }
        ]
      end

      before do
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return(alerts)

        create(:issue,
          project: project,
          title: "[Security] Upgrade minimatch — dependabot-alert-1",
          github_issue_id: id_offset + 1,
          github_state: "closed",
          paid_state: "completed",
          source: source)
      end

      it "re-opens the existing issue and returns it as actionable" do
        result = activity.execute(project_id: project.id)

        issue = project.issues.find_by(github_issue_id: id_offset + 1)
        expect(issue.github_state).to eq("open")
        expect(issue.paid_state).to eq("new")
        expect(issue.github_updated_at).to be_within(5.seconds).of(Time.current)

        expect(result[:alerts_to_fix].size).to eq(1)
        expect(result[:alerts_to_fix].first[:issue_id]).to eq(issue.id)
        expect(result[:alerts_to_fix].first[:alert_number]).to eq(1)
      end
    end

    context "when re-opened alerts exceed remaining capacity" do
      let(:alerts) do
        [
          { number: 10, state: "open", severity: "critical", package_name: "new-pkg",
            package_ecosystem: "npm", patched_version: "1.0.0", summary: "New vuln",
            html_url: "https://github.com/owner/repo/security/dependabot/10" },
          { number: 1, state: "open", severity: "high", package_name: "minimatch",
            package_ecosystem: "npm", patched_version: "3.0.5", summary: "ReDoS vulnerability",
            html_url: "https://github.com/owner/repo/security/dependabot/1" }
        ]
      end

      before do
        project.update!(max_security_fix_runs: 1)
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return(alerts)

        # Pre-existing closed issue for alert #1 — a re-open candidate
        create(:issue,
          project: project,
          title: "[Security] Upgrade minimatch — dependabot-alert-1",
          github_issue_id: id_offset + 1,
          github_state: "closed",
          paid_state: "completed",
          source: source)
      end

      it "does not reopen closed issues that exceed max_security_fix_runs" do
        result = activity.execute(project_id: project.id)

        # Only 1 slot: critical (#10) beats high (#1) regardless of new vs reopen
        expect(result[:alerts_to_fix].size).to eq(1)
        expect(result[:alerts_to_fix].first[:alert_number]).to eq(10)

        # The closed issue for alert #1 should NOT be reopened
        issue = project.issues.find_by(github_issue_id: id_offset + 1)
        expect(issue.github_state).to eq("closed")
        expect(issue.paid_state).to eq("completed")
      end
    end

    context "when a reopen candidate has higher severity than a new alert" do
      let(:alerts) do
        [
          { number: 20, state: "open", severity: "high", package_name: "new-pkg",
            package_ecosystem: "npm", patched_version: "1.0.0", summary: "New high vuln",
            html_url: "https://github.com/owner/repo/security/dependabot/20" },
          { number: 3, state: "open", severity: "critical", package_name: "old-pkg",
            package_ecosystem: "npm", patched_version: "2.0.0", summary: "Critical reopen vuln",
            html_url: "https://github.com/owner/repo/security/dependabot/3" }
        ]
      end

      before do
        project.update!(max_security_fix_runs: 1)
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return(alerts)

        # Pre-existing closed issue for alert #3 — a critical reopen candidate
        create(:issue,
          project: project,
          title: "[Security] Upgrade old-pkg — dependabot-alert-3",
          github_issue_id: id_offset + 3,
          github_state: "closed",
          paid_state: "completed",
          source: source)
      end

      it "picks the critical reopen candidate over the new high alert" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix].size).to eq(1)
        expect(result[:alerts_to_fix].first[:alert_number]).to eq(3)

        # The reopen candidate should be reopened
        issue = project.issues.find_by(github_issue_id: id_offset + 3)
        expect(issue.github_state).to eq("open")
        expect(issue.paid_state).to eq("new")

        # The new high alert should NOT have an issue created
        expect(project.issues.find_by(github_issue_id: id_offset + 20)).to be_nil
      end
    end

    context "when a dismissed alert is returned" do
      let(:alerts) do
        [
          {
            number: 1,
            state: "dismissed",
            severity: "high",
            package_name: "minimatch",
            package_ecosystem: "npm",
            patched_version: "3.0.5",
            summary: "ReDoS vulnerability",
            html_url: "https://github.com/owner/repo/security/dependabot/1"
          }
        ]
      end

      before do
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return(alerts)
      end

      it "skips non-open alerts" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
      end
    end

    context "when GitHub API returns a 403 error" do
      before do
        allow(github_client).to receive(:dependabot_alerts)
          .and_raise(GithubClient::ApiError.new("Dependabot alerts are not enabled", status: 403))
      end

      it "returns empty result gracefully" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
      end

      it "does not reconcile synthetic issues when fetch fails" do
        stale_issue = create(:issue,
          project: project,
          title: "[Security] Upgrade old-pkg — dependabot-alert-99",
          github_issue_id: id_offset + 99,
          github_state: "open",
          source: source)

        activity.execute(project_id: project.id)

        stale_issue.reload
        expect(stale_issue.github_state).to eq("open")
      end
    end

    context "when GitHub API returns a 5xx error" do
      before do
        allow(github_client).to receive(:dependabot_alerts)
          .and_raise(GithubClient::ApiError.new("Internal Server Error", status: 500))
      end

      it "re-raises so Temporal can retry" do
        expect { activity.execute(project_id: project.id) }.to raise_error(
          GithubClient::ApiError, /Internal Server Error/
        )
      end
    end

    context "when severity threshold is medium" do
      let(:alerts) do
        [
          { number: 1, state: "open", severity: "high", package_name: "foo",
            package_ecosystem: "npm", patched_version: "1.0.1", summary: "High vuln",
            html_url: "https://github.com/owner/repo/security/dependabot/1" },
          { number: 2, state: "open", severity: "low", package_name: "bar",
            package_ecosystem: "npm", patched_version: "2.0.0", summary: "Low vuln",
            html_url: "https://github.com/owner/repo/security/dependabot/2" }
        ]
      end

      before do
        project.update!(security_severity_threshold: "medium")
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return(alerts)
      end

      it "fetches all alerts and filters by severity locally" do
        result = activity.execute(project_id: project.id)

        # Only the high-severity alert should produce an issue; the low one
        # is below the "medium" threshold (critical/high/medium pass).
        expect(result[:alerts_to_fix].size).to eq(1)
        expect(result[:alerts_to_fix].first[:alert_number]).to eq(1)
      end
    end

    context "when severity threshold is raised above an existing synthetic issue" do
      let(:low_alert) do
        { number: 5, state: "open", severity: "low", package_name: "low-pkg",
          package_ecosystem: "npm", patched_version: "1.0.0", summary: "Low vuln",
          html_url: "https://github.com/owner/repo/security/dependabot/5" }
      end

      before do
        # Threshold is "high", so only critical/high pass, but alert #5 is low
        # and still open upstream.
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return([ low_alert ])

        create(:issue,
          project: project,
          title: "[Security] Upgrade low-pkg — dependabot-alert-5",
          github_issue_id: id_offset + 5,
          github_state: "open",
          source: source)
      end

      it "does not close the synthetic issue for an alert still open upstream" do
        activity.execute(project_id: project.id)

        issue = project.issues.find_by(github_issue_id: id_offset + 5)
        expect(issue.github_state).to eq("open")
      end
    end

    context "when a previously created synthetic issue is no longer in open alerts" do
      before do
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return([])

        create(:issue,
          project: project,
          title: "[Security] Upgrade old-pkg — dependabot-alert-99",
          github_issue_id: id_offset + 99,
          github_state: "open",
          source: source)
      end

      it "closes the stale synthetic issue and updates timestamps" do
        activity.execute(project_id: project.id)

        stale_issue = project.issues.find_by(github_issue_id: id_offset + 99)
        expect(stale_issue.github_state).to eq("closed")
        expect(stale_issue.paid_state).to eq("completed")
        expect(stale_issue.github_updated_at).to be_within(5.seconds).of(Time.current)
      end
    end

    context "when a stale synthetic issue has an active agent run" do
      let!(:stale_issue) do
        create(:issue,
          project: project,
          title: "[Security] Upgrade active-pkg — dependabot-alert-50",
          github_issue_id: id_offset + 50,
          github_state: "open",
          source: source)
      end

      before do
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return([])

        create(:agent_run, project: project, issue: stale_issue, status: "running")
      end

      it "does not close the issue while an agent run is active" do
        activity.execute(project_id: project.id)

        stale_issue.reload
        expect(stale_issue.github_state).to eq("open")
      end
    end

    context "when a stale synthetic issue has paid_state failed" do
      before do
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return([])

        create(:issue,
          project: project,
          title: "[Security] Upgrade failed-pkg — dependabot-alert-60",
          github_issue_id: id_offset + 60,
          github_state: "open",
          paid_state: "failed",
          source: source)
      end

      it "closes the github_state but preserves the failed paid_state" do
        activity.execute(project_id: project.id)

        issue = project.issues.find_by(github_issue_id: id_offset + 60)
        expect(issue.github_state).to eq("closed")
        expect(issue.paid_state).to eq("failed")
      end
    end

    context "when dependabot is not in alert types (empty)" do
      before do
        project.update!(security_alert_types: [])
      end

      it "does not fetch dependabot alerts" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
      end

      it "does not close existing synthetic dependabot issues" do
        stale_issue = create(:issue,
          project: project,
          title: "[Security] Upgrade old-pkg — dependabot-alert-99",
          github_issue_id: id_offset + 99,
          github_state: "open",
          source: source)

        activity.execute(project_id: project.id)

        stale_issue.reload
        expect(stale_issue.github_state).to eq("open")
      end
    end

    context "when no trusted GitHub usernames are configured" do
      let(:alerts) do
        [
          { number: 1, state: "open", severity: "high", package_name: "minimatch",
            package_ecosystem: "npm", patched_version: "3.0.5", summary: "ReDoS vulnerability",
            html_url: "https://github.com/owner/repo/security/dependabot/1" }
        ]
      end

      before do
        # Bypass validation to simulate a project with no trusted usernames,
        # since the model validates allowed_github_usernames is not empty.
        project.update_column(:allowed_github_usernames, [])
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name)
          .and_return(alerts)
      end

      it "raises a non-retryable error instead of creating an untrusted issue" do
        expect { activity.execute(project_id: project.id) }.to raise_error(
          Temporalio::Error::ApplicationError, /No trusted GitHub usernames configured/
        )
      end
    end

    context "when rate limited" do
      before do
        allow(github_client).to receive(:dependabot_alerts)
          .and_raise(GithubClient::RateLimitError.new(Time.current + 3600))
      end

      it "raises a retryable Temporal application error" do
        expect {
          activity.execute(project_id: project.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |e|
          expect(e.type).to eq("RateLimit")
          expect(e.non_retryable).to be false
        }
      end
    end

    context "when Dependabot is not enabled (NotFoundError)" do
      before do
        allow(github_client).to receive(:dependabot_alerts)
          .and_raise(GithubClient::NotFoundError)
      end

      it "returns empty actionable list" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
      end

      it "does not close existing synthetic issues" do
        stale_issue = create(:issue,
          project: project,
          title: "[Security] Upgrade old-pkg — dependabot-alert-99",
          github_issue_id: id_offset + 99,
          github_state: "open",
          source: source)

        activity.execute(project_id: project.id)

        stale_issue.reload
        expect(stale_issue.github_state).to eq("open")
      end
    end

    context "when alert types includes other types but not dependabot" do
      before do
        project.update!(security_alert_types: [ "code_scanning" ])
      end

      it "does not fetch dependabot alerts" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
      end

      it "does not close existing synthetic dependabot issues" do
        stale_issue = create(:issue,
          project: project,
          title: "[Security] Upgrade old-pkg — dependabot-alert-99",
          github_issue_id: id_offset + 99,
          github_state: "open",
          source: source)

        activity.execute(project_id: project.id)

        stale_issue.reload
        expect(stale_issue.github_state).to eq("open")
      end
    end
  end
end
