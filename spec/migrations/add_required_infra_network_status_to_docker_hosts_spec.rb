# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260822085848_add_required_infra_network_status_to_docker_hosts")

RSpec.describe AddRequiredInfraNetworkStatusToDockerHosts do
  let(:migration) { described_class.new }

  # @spec CONTAINER-RUNTIME-030
  it "backfills local hosts as infra-network ready only when the real local network probe succeeds" do
    host = create(:docker_host, :local, required_infra_network_status: described_class::UNKNOWN_STATUS)

    allow(Docker::Network).to receive(:get).with(described_class::INFRA_NETWORK_NAME)
      .and_return(instance_double(Docker::Network))

    expect {
      migrate_up
    }.to change { host.reload.required_infra_network_status }.from(described_class::UNKNOWN_STATUS).to("ready")
  end

  # @spec CONTAINER-RUNTIME-030
  it "does not backfill remote hosts as infra-network ready without real verification" do
    host = create(:docker_host, required_infra_network_status: described_class::UNKNOWN_STATUS)
    host.update_column(:required_network_name, "shared-agents")

    allow(Docker::Network).to receive(:get).with(described_class::INFRA_NETWORK_NAME)
      .and_raise(Docker::Error::NotFoundError.new("missing"))

    expect {
      migrate_up
    }.to change { host.reload.required_network_name }.from("shared-agents").to(NetworkPolicy::NETWORK_NAME)

    expect(host.required_infra_network_status).to eq(described_class::UNKNOWN_STATUS)
    expect(host).not_to be_placement_ready
  end

  def migrate_up
    ActiveRecord::Migration.suppress_messages do
      migration.send(:safety_assured) do
        migration.up
      end
    end
  end
end
