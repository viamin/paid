# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260822085848_add_required_infra_network_status_to_docker_hosts")

RSpec.describe AddRequiredInfraNetworkStatusToDockerHosts do
  let(:migration) { described_class.new }

  # @spec CONTAINER-RUNTIME-030
  it "does not backfill remote hosts as infra-network ready without real verification" do
    host = create(:docker_host, required_infra_network_status: described_class::UNKNOWN_STATUS)
    host.update_column(:required_network_name, "shared-agents")

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
