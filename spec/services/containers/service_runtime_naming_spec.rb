# frozen_string_literal: true

require "rails_helper"

# The alias is a shared contract: Containers::ServiceProvisioner registers it
# on the Docker network and points SERVICE_*_HOST env vars at it, and
# AgentRuns::EgressPolicy::Resolve records it in per-run policy snapshots.
RSpec.describe Containers::ServiceRuntimeNaming do
  describe ".runtime_name" do
    it "builds the paid-svc-<account>-<service>-<name> network alias" do
      account = create(:account)
      service = create(:service_container, account: account, name: "Primary Postgres", port: 5432)

      expect(described_class.runtime_name(service)).to eq("paid-svc-a#{account.id}-s#{service.id}-primary-postgres")
    end

    it "truncates the sanitized name segment to the Docker alias limit" do
      account = create(:account)
      service = create(:service_container, account: account, name: "a" * 100, port: 5432)

      expect(described_class.runtime_name(service)).to match(/\Apaid-svc-a#{account.id}-s#{service.id}-a{1,}\z/)
      expect(described_class.runtime_name(service).length).to be <= Containers::ServiceRuntimeNaming::MAX_NETWORK_ALIAS_LENGTH
    end

    it "falls back to a generic segment when the name sanitizes to nothing" do
      account = create(:account)
      service = create(:service_container, account: account, name: "***", port: 5432)

      expect(described_class.runtime_name(service)).to eq("paid-svc-a#{account.id}-s#{service.id}-service")
    end
  end
end
