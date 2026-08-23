# frozen_string_literal: true

class AddRequiredInfraNetworkStatusToDockerHosts < ActiveRecord::Migration[8.1]
  class MigrationDockerHost < ApplicationRecord
    self.table_name = "docker_hosts"
  end

  PRIMARY_NETWORK_NAME = "paid_agent"
  INFRA_NETWORK_NAME = "paid_internal"
  UNKNOWN_STATUS = "unknown"
  READY_STATUS = "ready"

  def up
    return unless table_exists?(:docker_hosts)

    unless column_exists?(:docker_hosts, :required_infra_network_status)
      add_column :docker_hosts, :required_infra_network_status, :string, null: false, default: UNKNOWN_STATUS,
        comment: "Whether the unrestricted paid_internal Docker network (subscription-auth/direct-outbound runs) exists on the host."
    end

    # docker_hosts enforces row-level security, so a backfill without system
    # access silently matches zero rows.
    TenantContext.with_system_access do
      MigrationDockerHost.unscoped.update_all(required_network_name: PRIMARY_NETWORK_NAME)
      backfill_local_infra_network_status if local_infra_network_ready?
    end
  end

  def down
    return unless column_exists?(:docker_hosts, :required_infra_network_status)

    remove_column :docker_hosts, :required_infra_network_status
  end

  private

  def backfill_local_infra_network_status
    MigrationDockerHost.unscoped.where(backend_type: "local")
      .update_all(required_infra_network_status: READY_STATUS)
  end

  def local_infra_network_ready?
    require "docker-api"

    # Existing local hosts never go through the remote setup wizard, so persist
    # the same real infra-network probe the runtime will rely on after deploy.
    Docker::Network.get(INFRA_NETWORK_NAME)
    true
  rescue StandardError => error
    say "Skipping local infra-network backfill: #{error.class}: #{error.message}"
    false
  end
end
