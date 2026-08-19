# frozen_string_literal: true

require "rails_helper"

# @spec EGRESS-POLICY-001
RSpec.describe EgressAllowlistEntry do
  describe "validations" do
    it "is valid with an exact public hostname" do
      expect(build(:egress_allowlist_entry, host_pattern: "api.example.com")).to be_valid
    end

    it "is valid with a leading-wildcard subdomain pattern" do
      expect(build(:egress_allowlist_entry, host_pattern: "*.packages.example.com")).to be_valid
    end

    it "normalizes the host pattern before validation" do
      entry = build(:egress_allowlist_entry, host_pattern: "  API.Example.COM  ")
      entry.valid?
      expect(entry.host_pattern).to eq("api.example.com")
    end

    {
      "bare wildcard" => "*",
      "wildcard TLD" => "*.com",
      "nested wildcard" => "*.*.example.com",
      "mid-host wildcard" => "foo.*.example.com",
      "trailing wildcard" => "*.example.*",
      "url with scheme" => "https://api.example.com",
      "url path" => "api.example.com/v1",
      "userinfo" => "user@api.example.com",
      "embedded port" => "api.example.com:443",
      "query string" => "api.example.com?x=1",
      "fragment" => "api.example.com#anchor",
      "ipv4 literal" => "203.0.113.10",
      "private ip" => "10.0.0.5",
      "loopback ip" => "127.0.0.1",
      "link-local ip" => "169.254.169.254",
      "localhost" => "localhost",
      "localhost subdomain" => "api.localhost",
      "wildcard localhost" => "*.localhost",
      "single label" => "example",
      "numeric tld" => "example.123",
      "empty label" => "api..example.com",
      "leading hyphen label" => "-api.example.com",
      "underscore" => "api_host.example.com",
      "blank" => "   "
    }.each do |label, pattern|
      it "rejects #{label} (#{pattern.inspect})" do
        entry = build(:egress_allowlist_entry, host_pattern: pattern)
        expect(entry).not_to be_valid
        expect(entry.errors[:host_pattern]).to be_present
      end
    end

    it "accepts any port between 1 and 65535" do
      expect(build(:egress_allowlist_entry, port: 65_535)).to be_valid
      expect(build(:egress_allowlist_entry, port: 1)).to be_valid
    end

    it "rejects out-of-range ports" do
      expect(build(:egress_allowlist_entry, port: 0)).not_to be_valid
      expect(build(:egress_allowlist_entry, port: 65_536)).not_to be_valid
    end

    it "accepts http and https schemes only" do
      expect(build(:egress_allowlist_entry, scheme: "https")).to be_valid
      expect(build(:egress_allowlist_entry, scheme: "ftp")).not_to be_valid
    end

    it "rejects a project from a different account" do
      other_project = create(:project)
      entry = build(:egress_allowlist_entry, project: other_project)

      expect(entry).not_to be_valid
      expect(entry.errors[:project]).to be_present
    end

    it "accepts a project-scoped entry for the same account" do
      account = create(:account)
      project = create(:project, account: account)
      entry = build(:egress_allowlist_entry, account: account, project: project)

      expect(entry).to be_valid
    end

    it "rejects a duplicate host within the same scope" do
      account = create(:account)
      create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com", port: 443)
      duplicate = build(:egress_allowlist_entry, account: account, host_pattern: "api.example.com", port: 443)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:host_pattern]).to include("is already allowlisted for this scope")
    end

    it "allows the same host in account and project scopes" do
      account = create(:account)
      project = create(:project, account: account)
      create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com")
      project_entry = build(:egress_allowlist_entry, account: account, project: project, host_pattern: "api.example.com")

      expect(project_entry).to be_valid
    end
  end

  describe ".enabled / .account_wide / .for_project scopes" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "separates enabled account-wide entries from project entries" do
      enabled_account = create(:egress_allowlist_entry, account: account, host_pattern: "a.example.com")
      create(:egress_allowlist_entry, account: account, host_pattern: "off.example.com", enabled: false)
      project_entry = create(:egress_allowlist_entry, account: account, project: project, host_pattern: "p.example.com")

      expect(described_class.enabled.account_wide.where(account: account)).to contain_exactly(enabled_account)
      expect(described_class.enabled.for_project(project)).to contain_exactly(project_entry)
    end
  end

  describe "#unsafe_reason" do
    it "returns nil for a safe persisted entry" do
      expect(create(:egress_allowlist_entry).unsafe_reason).to be_nil
    end

    it "returns the rejection reason for a row that bypassed write-time validation" do
      entry = build(:egress_allowlist_entry, host_pattern: "169.254.169.254")
      expect(entry.unsafe_reason).to eq("must not be an IP literal")
    end

    it "returns the rejection reason for a port that bypassed write-time validation" do
      entry = create(:egress_allowlist_entry)
      entry.update_column(:port, 70_000)
      expect(entry.unsafe_reason).to eq("port must be between 1 and 65535")
    end

    it "returns the rejection reason for a scheme that bypassed write-time validation" do
      entry = create(:egress_allowlist_entry)
      entry.update_column(:scheme, "ftp")
      expect(entry.unsafe_reason).to eq("scheme must be http or https")
    end
  end
end
