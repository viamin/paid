# frozen_string_literal: true

require "rails_helper"

RSpec.describe DockerHost, type: :model do
  it "is valid with the factory defaults" do
    expect(build(:docker_host)).to be_valid
  end

  # @spec CONTAINER-RUNTIME-030
  it "defaults the required network name to the runtime restricted network" do
    host = create(:docker_host, required_network_name: nil)

    expect(host.required_network_name).to eq(NetworkPolicy::NETWORK_NAME)
  end

  # @spec CONTAINER-RUNTIME-030
  it "normalizes arbitrary required network names back to the runtime restricted network" do
    host = create(:docker_host, required_network_name: "shared-agents")

    expect(host.required_network_name).to eq(NetworkPolicy::NETWORK_NAME)
  end

  # @spec CONTAINER-RUNTIME-030
  it "defaults the infra network status to unknown" do
    host = create(:docker_host, required_infra_network_status: nil)

    expect(host.required_infra_network_status).to eq("unknown")
  end

  # @spec CONTAINER-RUNTIME-030
  it "is not placement-ready when the infra network is not verified" do
    host = create(:docker_host, required_infra_network_status: "unknown")

    expect(host.placement_ready?).to be(false)
  end

  it "requires an endpoint for remote hosts" do
    host = build(:docker_host, endpoint: nil)

    expect(host).not_to be_valid
    expect(host.errors[:endpoint]).to include("can't be blank for remote Docker hosts")
  end

  it "forbids endpoints on the local host" do
    host = build(:docker_host, :local, endpoint: "tcp://localhost:2376")

    expect(host).not_to be_valid
    expect(host.errors[:endpoint]).to include("must be blank for the local Docker host")
  end

  it "does not allow identifier changes after create" do
    host = create(:docker_host)

    host.identifier = "renamed-host"

    expect(host).not_to be_valid
    expect(host.errors[:identifier]).to include("can't be changed after creation")
  end

  it "stores client TLS material encrypted at rest" do
    host = create(
      :docker_host,
      client_ca_pem: "-----BEGIN CERTIFICATE-----\nca\n-----END CERTIFICATE-----",
      client_certificate_pem: "-----BEGIN CERTIFICATE-----\nclient\n-----END CERTIFICATE-----",
      client_private_key_pem: "-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----"
    )

    expect(host.client_tls_material_present?).to be(true)
    expect(host.reload.read_attribute_before_type_cast("client_private_key_pem")).not_to include("BEGIN PRIVATE KEY")
  end

  # @spec CONTAINER-RUNTIME-030
  it "excludes hosts with an unverified infra network from placement-ready relations" do
    ready_host = create(:docker_host)
    infra_pending_host = create(:docker_host, account: ready_host.account, required_infra_network_status: "unknown")

    expect(ready_host.account.docker_hosts.placement_ready_for_restricted_agent_runs)
      .to contain_exactly(ready_host, infra_pending_host)
    expect(ready_host.account.docker_hosts.placement_ready_for_agent_runs).to contain_exactly(ready_host)
    expect(ready_host.account.docker_hosts.placement_ready_for_agent_runs).not_to include(infra_pending_host)
  end

  # @spec CONTAINER-RUNTIME-030
  it "requires the infra network status for local hosts so placement stays aligned with runtime checks" do
    host = create(:docker_host, :local, required_network_status: "ready", required_infra_network_status: "unknown")

    expect(host.placement_ready?).to be(false)
    expect(host.account.docker_hosts.placement_ready_for_agent_runs).to be_empty
  end

  # @spec EXEC-DISABLE-004
  it "excludes backend-disabled hosts from placement-ready relations" do
    enabled_host = create(:docker_host)
    disabled_host = create(:docker_host, account: enabled_host.account)
    create(:execution_control, :backend_scope, :enabled, docker_host: disabled_host)

    expect(enabled_host.account.docker_hosts.placement_ready_for_agent_runs).to contain_exactly(enabled_host)
  end

  # @spec EXEC-DISABLE-004
  describe ".disabled_placement_identifiers" do
    it "returns identifiers with an active backend-scoped execution control for the given account" do
      account = create(:account)
      other_account = create(:account)
      disabled_host = create(:docker_host, account: account)
      enabled_host = create(:docker_host, account: account)
      other_account_disabled_host = create(:docker_host, account: other_account, identifier: disabled_host.identifier)
      create(:execution_control, :backend_scope, :enabled, docker_host: disabled_host)
      create(:execution_control, :backend_scope, :enabled, docker_host: other_account_disabled_host)

      identifiers = described_class.disabled_placement_identifiers(account.id)

      expect(identifiers).to contain_exactly(disabled_host.identifier)
      expect(identifiers).not_to include(enabled_host.identifier)
    end

    it "ignores disabled (inactive) backend execution controls" do
      account = create(:account)
      host = create(:docker_host, account: account)
      create(:execution_control, :backend_scope, docker_host: host, enabled: false)

      expect(described_class.disabled_placement_identifiers(account.id)).to be_empty
    end
  end
end
