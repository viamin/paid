# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ScanSecurityAlertsActivity do
  let(:activity) { described_class.new }
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
          .with(project.full_name, severity: %w[critical high])
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
          .with(project.full_name, severity: %w[critical high])
          .and_return(alerts)
      end

      it "creates issues for each alert" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix].size).to eq(2)
        expect(result[:alerts_to_fix].first[:alert_number]).to eq(1)
        expect(result[:alerts_to_fix].first[:alert_type]).to eq("dependabot")
        expect(result[:alerts_to_fix].second[:alert_number]).to eq(2)
      end

      it "creates Issue records with correct attributes" do
        activity.execute(project_id: project.id)

        issue = project.issues.find_by(source: "dependabot_alert", github_issue_id: 9_000_000_001)
        expect(issue).to be_present
        expect(issue.title).to include("[Security]")
        expect(issue.title).to include("minimatch")
        expect(issue.title).to include("3.0.5")
        expect(issue.title).to include("dependabot-alert-1")
        expect(issue.body).to include("ReDoS vulnerability")
        expect(issue.labels).to include("security")
        expect(issue.paid_state).to eq("new")
        expect(issue.github_state).to eq("open")
        expect(issue.source).to eq("dependabot_alert")
      end

      it "sets a trusted creator login" do
        activity.execute(project_id: project.id)

        issue = project.issues.find_by(source: "dependabot_alert", github_issue_id: 9_000_000_001)
        expect(issue.trusted?).to be true
      end

      it "assigns synthetic github_numbers starting at 900_000" do
        activity.execute(project_id: project.id)

        numbers = project.issues.order(:id).pluck(:github_number)
        expect(numbers.first).to be >= 900_000
      end

      it "respects max_security_fix_runs limit" do
        project.update!(max_security_fix_runs: 1)

        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix].size).to eq(1)
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
          .with(project.full_name, severity: %w[critical high])
          .and_return(alerts)

        # Use the same synthetic github_issue_id that the activity generates
        # (9_000_000_000 + alert number) so the duplicate check matches.
        create(:issue,
          project: project,
          title: "[Security] Upgrade minimatch — dependabot-alert-1",
          github_issue_id: 9_000_000_001,
          github_state: "open",
          source: "dependabot_alert")
      end

      it "skips alerts that already have issues" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
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
          .with(project.full_name, severity: %w[critical high])
          .and_return(alerts)
      end

      it "skips non-open alerts" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
      end
    end

    context "when GitHub API returns an error" do
      before do
        allow(github_client).to receive(:dependabot_alerts)
          .and_raise(GithubClient::ApiError.new("Dependabot alerts are not enabled", status: 403))
      end

      it "returns empty result gracefully" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
      end
    end

    context "when severity threshold is medium" do
      before do
        project.update!(security_severity_threshold: "medium")
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name, severity: %w[critical high medium])
          .and_return([])
      end

      it "includes medium severity in the filter" do
        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:dependabot_alerts)
          .with(project.full_name, severity: %w[critical high medium])
      end
    end

    context "when a previously created synthetic issue is no longer in open alerts" do
      before do
        allow(github_client).to receive(:dependabot_alerts)
          .with(project.full_name, severity: %w[critical high])
          .and_return([])

        create(:issue,
          project: project,
          title: "[Security] Upgrade old-pkg — dependabot-alert-99",
          github_issue_id: 9_000_000_099,
          github_state: "open",
          source: "dependabot_alert")
      end

      it "closes the stale synthetic issue" do
        activity.execute(project_id: project.id)

        stale_issue = project.issues.find_by(github_issue_id: 9_000_000_099)
        expect(stale_issue.github_state).to eq("closed")
        expect(stale_issue.paid_state).to eq("resolved")
      end
    end

    context "when dependabot is not in alert types" do
      before do
        project.update!(security_alert_types: [])
      end

      it "does not fetch dependabot alerts" do
        result = activity.execute(project_id: project.id)

        expect(result[:alerts_to_fix]).to eq([])
      end
    end
  end
end
