# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::ScanSecurityAlertsActivity do
  let(:activity) { described_class.new }
  let(:project) do
    create(:project,
      auto_scan_security: true,
      security_alert_types: %w[code_scanning],
      security_severity_threshold: "high",
      code_scanning_interval_hours: 72)
  end
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
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

    context "with graceful 403/404 handling" do
      before { project.update_column(:last_code_scanning_scan_at, nil) }

      it "handles 404 gracefully and updates last_code_scanning_scan_at" do
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::NotFoundError.new("Not found"))

        expect { activity.execute(project_id: project.id) }.not_to raise_error

        project.reload
        expect(project.last_code_scanning_scan_at).to be_present
      end

      it "handles 403 gracefully and updates last_code_scanning_scan_at" do
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::ApiError.new("Forbidden", status: 403))

        expect { activity.execute(project_id: project.id) }.not_to raise_error

        project.reload
        expect(project.last_code_scanning_scan_at).to be_present
      end

      it "re-raises non-403 ApiError" do
        allow(github_client).to receive(:code_scanning_alerts)
          .and_raise(GithubClient::ApiError.new("Server error", status: 500))

        expect { activity.execute(project_id: project.id) }.to raise_error(GithubClient::ApiError)
      end
    end

    context "with reconciliation of stale synthetic issues" do
      let(:id_offset) { Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET }
      let(:number_offset) { 200_000_000 }

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
  end
end
