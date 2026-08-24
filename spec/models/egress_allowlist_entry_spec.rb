# frozen_string_literal: true

require "rails_helper"

# @spec EGRESS-POLICY-001
RSpec.describe EgressAllowlistEntry do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:created_by).optional }
  end

  describe ".host_pattern_valid?" do
    it "accepts exact hostnames and leading-wildcard subdomains" do
      expect(described_class.host_pattern_valid?("api.example.com")).to be(true)
      expect(described_class.host_pattern_valid?("*.packages.example.com")).to be(true)
    end

    it "rejects unsafe shapes" do
      %w[
        *
        *.com
        *.*.example.com
        foo.*.example.com
        api.example.com/v1
        user@api.example.com
        api.example.com:443
        127.0.0.1
        localhost
        localhost.localdomain
        api.local
        api.test
      ].each do |pattern|
        expect(described_class.host_pattern_valid?(pattern)).to be(false)
      end
    end
  end

  describe "validations" do
    let(:account) { create(:account) }
    let(:malformed_host_patterns) do
      %w[
        *
        *.*.example.com
        foo.*.example.com
        *.example.*
        https://api.example.com
        api.example.com/v1
        user@api.example.com
        api.example.com:443
        api.example.com?x=1
        api.example.com#anchor
        203.0.113.10
        127.0.0.1.example.com
        api.169.254.169.254.example.com
        api.localhost
        *.localhost
        example
        example.123
        api..example.com
        -api.example.com
        api_host.example.com
      ] + [ "   " ]
    end

    it "is valid with an exact public hostname" do
      expect(build(:egress_allowlist_entry, account: account, host_pattern: "api.example.com")).to be_valid
    end

    it "is valid with a leading-wildcard subdomain pattern" do
      expect(build(:egress_allowlist_entry, account: account, host_pattern: "*.packages.example.com")).to be_valid
    end

    it "is valid with hostnames that have two-letter public TLDs" do
      expect(build(:egress_allowlist_entry, account: account, host_pattern: "api.example.ai")).to be_valid
      expect(build(:egress_allowlist_entry, account: account, host_pattern: "api.example.io")).to be_valid
      expect(build(:egress_allowlist_entry, account: account, host_pattern: "api.example.uk")).to be_valid
    end

    it "normalizes the host pattern before validation" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "  API.Example.COM  ")

      entry.valid?

      expect(entry.host_pattern).to eq("api.example.com")
    end

    it "rejects wildcard TLDs with an actionable message" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "*.com")

      expect(entry).not_to be_valid
      expect(entry.errors[:host_pattern].join).to include("Wildcard top-level domains")
    end

    it "rejects loopback hosts with an actionable message" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "localhost")

      expect(entry).not_to be_valid
      expect(entry.errors[:host_pattern].join).to match(/loopback/i)
    end

    it "rejects private network IP literals with an actionable message" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "10.1.2.3")

      expect(entry).not_to be_valid
      expect(entry.errors[:host_pattern].join).to match(/private network/i)
    end

    it "rejects cloud metadata IP literals with an actionable message" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "169.254.169.254")

      expect(entry).not_to be_valid
      expect(entry.errors[:host_pattern].join).to match(/metadata/i)
    end

    it "rejects hostnames that embed IP literals inside a domain rule" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "127.0.0.1.example.com")

      expect(entry).not_to be_valid
      expect(entry.errors[:host_pattern].join).to include("hostname")
    end

    it "rejects malformed hostnames" do
      malformed_host_patterns.each do |pattern|
        entry = build(:egress_allowlist_entry, account: account, host_pattern: pattern)
        expect(entry).not_to be_valid
        expect(entry.errors[:host_pattern]).to be_present
      end
    end

    it "accepts any port between 1 and 65535" do
      expect(build(:egress_allowlist_entry, account: account, port: 1)).to be_valid
      expect(build(:egress_allowlist_entry, account: account, port: 65_535)).to be_valid
    end

    it "rejects out-of-range ports" do
      expect(build(:egress_allowlist_entry, account: account, port: 0)).not_to be_valid
      expect(build(:egress_allowlist_entry, account: account, port: 65_536)).not_to be_valid
    end

    it "does not add a host-pattern error for an invalid port" do
      entry = build(:egress_allowlist_entry, account: account, port: 0)

      expect(entry).not_to be_valid
      expect(entry.errors[:port]).to include("must be between 1 and 65535")
      expect(entry.errors[:host_pattern]).to be_empty
    end

    it "accepts http and https schemes only" do
      expect(build(:egress_allowlist_entry, account: account, scheme: "https")).to be_valid
      expect(build(:egress_allowlist_entry, account: account, scheme: "ftp")).not_to be_valid
    end

    it "validates source_kind inclusion" do
      entry = build(:egress_allowlist_entry, account: account, source_kind: "rogue")

      expect(entry).not_to be_valid
      expect(entry.errors[:source_kind]).to be_present
    end

    it "rejects a project from a different account" do
      other_project = create(:project)
      entry = build(:egress_allowlist_entry, account: account, project: other_project)

      expect(entry).not_to be_valid
      expect(entry.errors[:project]).to be_present
    end

    it "accepts a project-scoped entry for the same account" do
      project = create(:project, account: account)
      entry = build(:egress_allowlist_entry, account: account, project: project)

      expect(entry).to be_valid
    end

    it "rejects a duplicate host within the same scope" do
      create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com", port: 443)
      duplicate = build(:egress_allowlist_entry, account: account, host_pattern: "api.example.com", port: 443)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:host_pattern].join).to include("already exists")
    end

    it "allows the same host in account and project scopes" do
      project = create(:project, account: account)
      create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com")
      project_entry = build(:egress_allowlist_entry, account: account, project: project, host_pattern: "api.example.com")

      expect(project_entry).to be_valid
    end
  end

  describe "database uniqueness enforcement" do
    let(:account) { create(:account) }

    it "rejects duplicate account-level rows with null scheme and port at the database level" do
      create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com")

      duplicate = build(:egress_allowlist_entry, account: account, host_pattern: "api.example.com")
      expect { duplicate.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "rejects duplicate project-level rows with null scheme and port at the database level" do
      project = create(:project, account: account)
      create(:egress_allowlist_entry, :project_level, account: account, project: project, host_pattern: "api.example.com")

      duplicate = build(:egress_allowlist_entry, :project_level, account: account, project: project, host_pattern: "api.example.com")
      expect { duplicate.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe ".enabled / .account_wide / .for_project / .for_account scopes" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "separates enabled account-wide entries from project entries" do
      enabled_account = create(:egress_allowlist_entry, account: account, host_pattern: "a.example.com")
      disabled_account = create(:egress_allowlist_entry, :disabled, account: account, host_pattern: "off.example.com")
      project_entry = create(:egress_allowlist_entry, :project_level, account: account, project: project, host_pattern: "p.example.com")

      expect(described_class.enabled.account_wide.where(account: account)).to contain_exactly(enabled_account)
      expect(described_class.enabled.for_project(project)).to contain_exactly(project_entry)
      expect(described_class.for_account(account)).to contain_exactly(enabled_account, disabled_account)
    end
  end

  describe "#matches?" do
    let(:account) { create(:account) }

    it "matches an exact host when enabled" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "api.example.com", enabled: true)

      expect(entry.matches?(host: "api.example.com")).to be(true)
      expect(entry.matches?(host: "example.com")).to be(false)
    end

    it "matches subdomains when the entry uses a wildcard" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "*.packages.example.com", enabled: true)

      expect(entry.matches?(host: "npm.packages.example.com")).to be(true)
      expect(entry.matches?(host: "packages.example.com")).to be(false)
    end

    it "respects scheme and port filters" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "api.example.com", scheme: "https", port: 8443, enabled: true)

      expect(entry.matches?(host: "api.example.com", scheme: "https", port: 8443)).to be(true)
      expect(entry.matches?(host: "api.example.com", scheme: "https", port: 9000)).to be(false)
      expect(entry.matches?(host: "api.example.com", scheme: "http", port: 8443)).to be(false)
    end

    it "rejects matches when the entry is disabled" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "api.example.com", enabled: false)

      expect(entry.matches?(host: "api.example.com")).to be(false)
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
      entry.port = 70_000

      expect(entry.unsafe_reason).to eq("port must be between 1 and 65535")
    end

    it "returns the rejection reason for a scheme that bypassed write-time validation" do
      entry = create(:egress_allowlist_entry)
      entry.scheme = "ftp"

      expect(entry.unsafe_reason).to eq("scheme must be http or https")
    end
  end

  describe "disabled_at bookkeeping" do
    let(:account) { create(:account) }

    it "stamps disabled_at when transitioning from enabled to disabled" do
      entry = create(:egress_allowlist_entry, account: account, enabled: true)

      expect(entry.disabled_at).to be_nil

      entry.update!(enabled: false)

      expect(entry.reload.disabled_at).to be_within(5.seconds).of(Time.current)
    end

    it "clears disabled_at when transitioning back to enabled" do
      entry = create(:egress_allowlist_entry, account: account, enabled: false, disabled_at: 1.day.ago)

      entry.update!(enabled: true)

      expect(entry.reload.disabled_at).to be_nil
    end
  end
end
