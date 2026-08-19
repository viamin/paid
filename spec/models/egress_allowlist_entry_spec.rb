# frozen_string_literal: true

require "rails_helper"

RSpec.describe EgressAllowlistEntry do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project).optional }
    it { is_expected.to belong_to(:created_by).optional }
  end

  describe ".host_pattern_valid?" do
    it "accepts exact hostnames" do
      expect(described_class.host_pattern_valid?("api.example.com")).to be(true)
      expect(described_class.host_pattern_valid?("deeply.nested.packages.example.com")).to be(true)
    end

    it "accepts leading-wildcard subdomains" do
      expect(described_class.host_pattern_valid?("*.example.com")).to be(true)
      expect(described_class.host_pattern_valid?("*.packages.example.com")).to be(true)
    end

    it "rejects blank or overlong values" do
      expect(described_class.host_pattern_valid?("")).to be(false)
      expect(described_class.host_pattern_valid?(nil)).to be(false)
      expect(described_class.host_pattern_valid?("a" * 256)).to be(false)
    end

    it "rejects wildcard TLDs" do
      expect(described_class.host_pattern_valid?("*.com")).to be(false)
      expect(described_class.host_pattern_valid?("*.local")).to be(false)
    end

    it "rejects internal wildcards" do
      expect(described_class.host_pattern_valid?("*.*.example.com")).to be(false)
      expect(described_class.host_pattern_valid?("api.*.example.com")).to be(false)
    end

    it "rejects paths, userinfo, query strings, ports, or schemes embedded in the host" do
      expect(described_class.host_pattern_valid?("api.example.com/path")).to be(false)
      expect(described_class.host_pattern_valid?("user:pass@example.com")).to be(false)
      expect(described_class.host_pattern_valid?("api.example.com?q=1")).to be(false)
      expect(described_class.host_pattern_valid?("api.example.com:443")).to be(false)
      expect(described_class.host_pattern_valid?("https://api.example.com")).to be(false)
    end

    it "rejects IP literals and loopback aliases" do
      expect(described_class.host_pattern_valid?("127.0.0.1")).to be(false)
      expect(described_class.host_pattern_valid?("10.0.0.1")).to be(false)
      expect(described_class.host_pattern_valid?("192.168.1.1")).to be(false)
      expect(described_class.host_pattern_valid?("localhost")).to be(false)
    end

    it "rejects any IP literal regardless of octet length" do
      expect(described_class.host_pattern_valid?("192.0.2.10")).to be(false)
      expect(described_class.host_pattern_valid?("8.8.8.8")).to be(false)
      expect(described_class.host_pattern_valid?("169.254.169.254")).to be(false)
      expect(described_class.host_pattern_valid?("::1")).to be(false)
      expect(described_class.host_pattern_valid?("fe80::1")).to be(false)
    end
  end

  describe "validations" do
    let(:account) { create(:account) }

    it "requires a host pattern" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "")
      expect(entry).not_to be_valid
      expect(entry.errors[:host_pattern]).to be_present
    end

    it "rejects unsafe host patterns with an actionable message" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "*.com")
      expect(entry).not_to be_valid
      expect(entry.errors[:host_pattern].join).to include('top-level domain')
    end

    it "rejects loopback hosts" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "localhost")
      expect(entry).not_to be_valid
      expect(entry.errors[:host_pattern].join).to match(/loopback/i)
    end

    it "rejects wildcard entries with internal wildcards" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "*.*.example.com")
      expect(entry).not_to be_valid
      expect(entry.errors[:host_pattern].join).to match(/wildcard/i)
    end

    it "rejects numeric loopback IP literals with an actionable message" do
      entry = build(:egress_allowlist_entry, account: account, host_pattern: "127.0.0.5")
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

    it "validates scheme inclusion" do
      entry = build(:egress_allowlist_entry, account: account, scheme: "ftp")
      expect(entry).not_to be_valid
      expect(entry.errors[:scheme]).to be_present
    end

    it "validates source_kind inclusion" do
      entry = build(:egress_allowlist_entry, account: account, source_kind: "rogue")
      expect(entry).not_to be_valid
      expect(entry.errors[:source_kind]).to be_present
    end

    it "validates port range" do
      entry = build(:egress_allowlist_entry, account: account, port: 0)
      expect(entry).not_to be_valid
      expect(entry.errors[:port]).to be_present

      entry = build(:egress_allowlist_entry, account: account, port: 70_000)
      expect(entry).not_to be_valid
      expect(entry.errors[:port]).to be_present
    end

    it "rejects duplicate account-level host patterns" do
      create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com")
      duplicate = build(:egress_allowlist_entry, account: account, host_pattern: "api.example.com")
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:host_pattern].join).to include('already exists')
    end

    it "permits identical host patterns across accounts" do
      other_account = create(:account)
      create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com")
      entry = build(:egress_allowlist_entry, account: other_account, host_pattern: "api.example.com")
      expect(entry).to be_valid
    end

    it "permits identical host patterns across scopes within the same account" do
      project = create(:project, account: account)
      create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com")
      entry = build(:egress_allowlist_entry, account: account, project: project, host_pattern: "api.example.com")
      expect(entry).to be_valid
    end

    it "persists entries that share a host pattern but differ by scheme or port" do
      create(:egress_allowlist_entry, account: account, host_pattern: "api.example.com", scheme: "https", port: 443)

      by_port = build(:egress_allowlist_entry, account: account, host_pattern: "api.example.com", scheme: "https", port: 8443)
      by_scheme = build(:egress_allowlist_entry, account: account, host_pattern: "api.example.com", scheme: "http", port: 443)

      expect(by_port).to be_valid
      expect { by_port.save! }.not_to raise_error
      expect(by_scheme).to be_valid
      expect { by_scheme.save! }.not_to raise_error
    end

    it "rejects project-level entries that reference a project from a different account" do
      other_project = create(:project)
      entry = build(:egress_allowlist_entry, account: account, project: other_project)
      expect(entry).not_to be_valid
      expect(entry.errors[:project].join).to include('must belong')
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

  describe ".for_account and .for_project" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    it "scopes queries by tenant and project level" do
      account_entry = create(:egress_allowlist_entry, account: account)
      project_entry = create(:egress_allowlist_entry, :project_level, account: account, project: project)

      expect(described_class.for_account(account)).to include(account_entry)
      expect(described_class.for_account(account)).not_to include(project_entry)
      expect(described_class.for_project(project)).to include(project_entry)
      expect(described_class.for_project(project)).not_to include(account_entry)
    end
  end
end
