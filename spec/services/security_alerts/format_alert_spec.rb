# frozen_string_literal: true

require "rails_helper"

RSpec.describe SecurityAlerts::FormatAlert do
  let(:alert) do
    {
      number: 1,
      state: "open",
      severity: "high",
      package_name: "minimatch",
      package_ecosystem: "npm",
      patched_version: "3.0.5",
      summary: "ReDoS vulnerability in minimatch",
      html_url: "https://github.com/owner/repo/security/dependabot/1"
    }
  end

  describe ".title" do
    it "includes package name, patched version, severity, and alert identifier" do
      title = described_class.title(alert)

      expect(title).to include("[Security]")
      expect(title).to include("minimatch")
      expect(title).to include("3.0.5")
      expect(title).to include("(high)")
      expect(title).to include("dependabot-alert-1")
    end

    it "handles alerts with minimal fields" do
      minimal = { number: 5 }

      title = described_class.title(minimal)

      expect(title).to include("[Security]")
      expect(title).to include("dependabot-alert-5")
    end
  end

  describe ".body" do
    it "includes alert details and upgrade instructions" do
      body = described_class.body(alert)

      expect(body).to include("Dependabot Security Alert #1")
      expect(body).to include("**Severity:** high")
      expect(body).to include("minimatch")
      expect(body).to include("3.0.5")
      expect(body).to include("ReDoS vulnerability")
      expect(body).to include("Upgrade `minimatch` to version `3.0.5`")
      expect(body).to include("View alert on GitHub")
    end

    it "uses generic instructions when patched version is missing" do
      alert_without_patch = alert.except(:patched_version)

      body = described_class.body(alert_without_patch)

      expect(body).to include("Fix the security vulnerability described above")
    end

    it "omits ecosystem parentheses when package_ecosystem is nil" do
      alert_without_ecosystem = alert.except(:package_ecosystem)

      body = described_class.body(alert_without_ecosystem)

      expect(body).to include("**Package:** minimatch")
      expect(body).not_to include("()")
    end
  end
end
