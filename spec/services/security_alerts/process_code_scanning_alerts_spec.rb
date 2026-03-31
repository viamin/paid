# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityAlerts::ProcessCodeScanningAlerts do
  let(:project) do
    create(:project,
      auto_scan_security: true,
      security_alert_types: %w[dependabot code_scanning])
  end
  let(:id_offset) { Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET }
  let(:source) { Issue::SYNTHETIC_CODE_SCANNING_SOURCE }

  let(:alert) do
    {
      number: 1667,
      state: "open",
      severity: "high",
      rule_id: "py/sensitive-get-query",
      rule_description: "Sensitive data read from GET request",
      tool_name: "CodeQL",
      summary: "Reading sensitive data from a GET request.",
      html_url: "https://github.com/owner/repo/security/code-scanning/1667",
      created_at: "2026-03-29T10:00:00Z",
      updated_at: "2026-03-29T12:00:00Z"
    }
  end

  describe "#call" do
    it "creates a synthetic issue for a new alert" do
      described_class.new(project).call([ alert ])

      issue = project.issues.find_by(source: source, github_issue_id: id_offset + 1667)
      expect(issue).to be_present
      expect(issue.title).to include("[Security] CodeQL:")
      expect(issue.title).to include("code-scanning-alert-1667")
      expect(issue.body).to include("Code Scanning Alert #1667")
      expect(issue.labels).to eq(%w[security code-scanning])
      expect(issue.paid_state).to eq("new")
      expect(issue.github_state).to eq("open")
      expect(issue.source).to eq(source)
    end

    it "skips non-open alerts" do
      dismissed_alert = alert.merge(state: "dismissed")

      described_class.new(project).call([ dismissed_alert ])

      expect(project.issues.where(source: source).count).to eq(0)
    end

    it "reopens a closed issue when the alert reappears" do
      existing = create(:issue,
        project: project,
        github_issue_id: id_offset + 1667,
        github_number: 200_001_667,
        source: source,
        github_state: "closed",
        paid_state: "completed")

      described_class.new(project).call([ alert ])

      existing.reload
      expect(existing.github_state).to eq("open")
      expect(existing.paid_state).to eq("new")
    end

    it "updates metadata when an existing open issue has changed alert payload" do
      existing = create(:issue,
        project: project,
        github_issue_id: id_offset + 1667,
        github_number: 200_001_667,
        source: source,
        github_state: "open",
        paid_state: "new",
        title: "Old title",
        body: "Old body")

      described_class.new(project).call([ alert ])

      existing.reload
      expect(existing.title).to include("code-scanning-alert-1667")
      expect(existing.body).to include("Code Scanning Alert #1667")
    end

    it "does not update when metadata is unchanged" do
      title = SecurityAlerts::FormatCodeScanningAlert.title(alert)
      body = SecurityAlerts::FormatCodeScanningAlert.body(alert)

      existing = create(:issue,
        project: project,
        github_issue_id: id_offset + 1667,
        github_number: 200_001_667,
        source: source,
        github_state: "open",
        paid_state: "new",
        title: title,
        body: body)

      expect { described_class.new(project).call([ alert ]) }
        .not_to change { existing.reload.updated_at }
    end

    it "handles duplicate creation race gracefully" do
      create(:issue,
        project: project,
        github_issue_id: id_offset + 1667,
        github_number: 200_001_667,
        source: source,
        github_state: "open",
        paid_state: "new")

      # Should not raise — the existing issue covers it
      expect { described_class.new(project).call([ alert ]) }.not_to raise_error
    end

    it "raises ConfigurationError when no trusted usernames are configured" do
      project.update_column(:allowed_github_usernames, [])

      expect { described_class.new(project).call([ alert ]) }
        .to raise_error(SecurityAlerts::ConfigurationError)
    end
  end
end
