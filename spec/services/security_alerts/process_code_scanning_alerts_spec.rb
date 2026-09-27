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
    # @spec GITHUB-SYNC-015
    it "refreshes an existing issue with finding context and prior run evidence" do
      existing = create(:issue, project: project, github_issue_id: id_offset + 1667,
        github_number: 200_001_667, source: source, github_state: "open", paid_state: "new")
      create(:agent_run, project: project, issue: existing, status: "failed", pull_request_url: "https://github.com/owner/repo/pull/3")
      enriched = alert.merge(ref: "refs/heads/main", commit_sha: "a" * 40,
        analysis_key: "dynamic/codeql", category: "/language:ruby",
        location: { path: "app/controllers/runners_controller.rb", start_line: 69, end_line: 69,
                    start_column: 36, end_column: 42 })

      described_class.new(project).call([ enriched ])

      expect(existing.reload.body).to include("app/controllers/runners_controller.rb:69:36-69:42")
      expect(existing.body).to include("Run ##{existing.agent_runs.first.id}: failed")
    end

    # @spec GITHUB-SYNC-015
    it "excludes the specified run from prior attempts so a run being started does not list itself" do
      existing = create(:issue, project: project, github_issue_id: id_offset + 1667,
        github_number: 200_001_667, source: source, github_state: "open", paid_state: "new")
      current_run = create(:agent_run, project: project, issue: existing, status: "running")
      prior_run = create(:agent_run, project: project, issue: existing, status: "failed",
        created_at: 1.day.ago, pull_request_url: "https://github.com/owner/repo/pull/3")

      described_class.new(project).call([ alert ], excluding_run_id: current_run.id)

      expect(existing.reload.body).to include("Run ##{prior_run.id}: failed")
      expect(existing.body).not_to include("Run ##{current_run.id}:")
    end


    it "carries the alert-1838 finding context into the final issue prompt" do
      # @spec GITHUB-SYNC-015
      alert_1838 = alert.merge(number: 1838, rule_id: "rb/sensitive-get-query",
        summary: "Sensitive data read from a GET request.", ref: "refs/heads/main",
        commit_sha: "7cabdb70d31b3056128f97f629213260dad4be49",
        analysis_key: "dynamic/github-code-scanning/codeql:analyze", category: "/language:ruby",
        location: { path: "app/controllers/runners_controller.rb", start_line: 69, end_line: 69,
                    start_column: 36, end_column: 42 })
      described_class.new(project).call([ alert_1838 ])
      issue = project.issues.find_by!(github_issue_id: id_offset + 1838)

      prompt = Prompts::BuildForIssue.call(issue: issue, project: project)

      expect(prompt).to include("app/controllers/runners_controller.rb:69:36-69:42")
      expect(prompt).to include("refs/heads/main")
      expect(prompt).to include("7cabdb70d31b3056128f97f629213260dad4be49")
      expect(prompt).to include("dynamic/github-code-scanning/codeql:analyze")
      expect(prompt).to include("Sensitive data read from a GET request.")
    end

    it "creates a synthetic issue for a new alert" do
      described_class.new(project).call([ alert ])

      issue = project.issues.find_by(source: source, github_issue_id: id_offset + 1667)
      expect(issue).to be_present
      expect(issue.title).to include("[Security] CodeQL:")
      expect(issue.title).to include("code-scanning-alert-1667")
      expect(issue.body).to include("Code Scanning Alert #1667")
      expect(issue.labels).to eq(%w[security code-scanning P1])
      expect(issue.paid_state).to eq("new")
      expect(issue.github_state).to eq("open")
      expect(issue.source).to eq(source)
    end

    it "maps severity to priority label" do
      {
        "critical" => "P1",
        "high" => "P1",
        "medium" => "P2",
        "low" => "P3"
      }.each.with_index(1) do |(severity, priority), index|
        medium_alert = alert.merge(number: 10_000 + index, severity: severity)

        described_class.new(project).call([ medium_alert ])

        issue = project.issues.find_by(source: source, github_issue_id: id_offset + medium_alert[:number])
        expect(issue.labels).to include(priority),
          "Expected severity #{severity.inspect} to include priority #{priority.inspect}, got #{issue.labels.inspect}"
      end
    end

    it "uses custom project priority labels" do
      project.update!(priority_labels: { "P1" => "urgent", "P2" => "normal", "P3" => "low" })

      described_class.new(project).call([ alert.merge(severity: "medium") ])

      issue = project.issues.find_by(source: source, github_issue_id: id_offset + 1667)
      expect(issue.labels).to eq(%w[security code-scanning normal])
    end

    it "skips non-open alerts" do
      dismissed_alert = alert.merge(state: "dismissed")

      described_class.new(project).call([ dismissed_alert ])

      expect(project.issues.where(source: source).count).to eq(0)
    end

    it "closes an existing open issue when a refreshed alert is no longer open" do
      # @spec GITHUB-SYNC-015
      existing = create(:issue, project: project, github_issue_id: id_offset + 1667,
        github_number: 200_001_667, source: source, github_state: "open", paid_state: "in_progress")
      dismissed_alert = alert.merge(state: "dismissed")

      described_class.new(project).call([ dismissed_alert ])

      existing.reload
      expect(existing.github_state).to eq("closed")
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
      expect(existing.labels).to eq(%w[security code-scanning P1])
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
      expect(existing.labels).to eq(%w[security code-scanning P1])
    end

    it "updates priority label when an existing open issue severity changes" do
      title = SecurityAlerts::FormatCodeScanningAlert.title(alert)
      body = SecurityAlerts::FormatCodeScanningAlert.body(alert.merge(repository: project.full_name))
      existing = create(:issue,
        project: project,
        github_issue_id: id_offset + 1667,
        github_number: 200_001_667,
        source: source,
        github_state: "open",
        paid_state: "new",
        title: title,
        body: body,
        labels: %w[security code-scanning P3])

      described_class.new(project).call([ alert.merge(severity: "medium") ])

      expect(existing.reload.labels).to eq(%w[security code-scanning P2])
    end

    it "does not update when metadata is unchanged" do
      title = SecurityAlerts::FormatCodeScanningAlert.title(alert)
      body = SecurityAlerts::FormatCodeScanningAlert.body(alert.merge(repository: project.full_name))

      existing = create(:issue,
        project: project,
        github_issue_id: id_offset + 1667,
        github_number: 200_001_667,
        source: source,
        github_state: "open",
        paid_state: "new",
        title: title,
        body: body,
        labels: %w[security code-scanning P1])

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
