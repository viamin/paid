# frozen_string_literal: true

require "rails_helper"

RSpec.describe DockerHost, type: :model do
  it "is valid with the factory defaults" do
    expect(build(:docker_host)).to be_valid
  end

  it "defaults the required network name" do
    host = create(:docker_host, required_network_name: nil)

    expect(host.required_network_name).to eq("paid-agents")
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

  # @spec EXEC-DISABLE-004
  it "excludes backend-disabled hosts from placement-ready relations" do
    enabled_host = create(:docker_host)
    disabled_host = create(:docker_host, account: enabled_host.account)
    create(:execution_control, :backend_scope, :enabled, docker_host: disabled_host)

    expect(enabled_host.account.docker_hosts.placement_ready_for_agent_runs).to contain_exactly(enabled_host)
  end
end
