# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityAlerts::FormatCodeScanningAlert do
  let(:alert) do
    {
      number: 1667,
      state: "open",
      severity: "high",
      rule_id: "py/sensitive-get-query",
      rule_description: "Sensitive data read from GET request",
      tool_name: "CodeQL",
      summary: "Reading sensitive data from a GET request query string may expose it.",
      html_url: "https://github.com/owner/repo/security/code-scanning/1667"
    }
  end

  describe ".title" do
    it "includes rule description, severity, and alert identifier" do
      title = described_class.title(alert)

      expect(title).to include("[Security] CodeQL:")
      expect(title).to include("Sensitive data read from GET request")
      expect(title).to include("(high)")
      expect(title).to include("code-scanning-alert-1667")
    end

    it "handles alerts with minimal fields" do
      minimal = { number: 5 }

      title = described_class.title(minimal)

      expect(title).to include("[Security] CodeQL:")
      expect(title).to include("code-scanning-alert-5")
    end
  end

  describe ".body" do
    it "includes alert details and remediation instructions" do
      body = described_class.body(alert)

      expect(body).to include("Code Scanning Alert #1667")
      expect(body).to include("**Severity:** high")
      expect(body).to include("**Rule:** py/sensitive-get-query")
      expect(body).to include("**Tool:** CodeQL")
      expect(body).to include("Reading sensitive data")
      expect(body).to include("Fix the code scanning alert")
      expect(body).to include("View alert on GitHub")
    end

    it "omits optional fields when absent" do
      minimal = { number: 5, severity: "medium" }

      body = described_class.body(minimal)

      expect(body).to include("Code Scanning Alert #5")
      expect(body).to include("**Severity:** medium")
      expect(body).not_to include("**Rule:**")
      expect(body).not_to include("**Tool:**")
      expect(body).not_to include("**Summary:**")
      expect(body).not_to include("View alert on GitHub")
    end
  end
end
