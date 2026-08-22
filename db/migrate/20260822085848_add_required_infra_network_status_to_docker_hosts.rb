# frozen_string_literal: true

class AddRequiredInfraNetworkStatusToDockerHosts < ActiveRecord::Migration[8.1]
  PRIMARY_NETWORK_NAME = "paid_agent"
  INFRA_NETWORK_NAME = "paid_internal"
  UNKNOWN_STATUS = "unknown"
  READY_STATUS = "ready"

  def up
    unless column_exists?(:docker_hosts, :required_infra_network_status)
      add_column :docker_hosts, :required_infra_network_status, :string, null: false, default: UNKNOWN_STATUS,
        comment: "Whether the unrestricted paid_internal Docker network (subscription-auth/direct-outbound runs) exists on the host."
    end

    return unless table_exists?(:docker_hosts)

    execute <<~SQL.squish
      UPDATE docker_hosts
      SET
        required_network_name = '#{PRIMARY_NETWORK_NAME}'
      WHERE required_network_name IS DISTINCT FROM '#{PRIMARY_NETWORK_NAME}'
    SQL

    backfill_local_infra_network_status if local_infra_network_ready?
  end

  def down
    return unless column_exists?(:docker_hosts, :required_infra_network_status)

    remove_column :docker_hosts, :required_infra_network_status
  end

  private

  def backfill_local_infra_network_status
    execute <<~SQL.squish
      UPDATE docker_hosts
      SET required_infra_network_status = '#{READY_STATUS}'
      WHERE backend_type = 'local'
        AND required_infra_network_status IS DISTINCT FROM '#{READY_STATUS}'
    SQL
  end

  def local_infra_network_ready?
    require "docker-api"

    # Existing local hosts never go through the remote setup wizard, so persist
    # the same real infra-network probe the runtime will rely on after deploy.
    Docker::Network.get(INFRA_NETWORK_NAME)
    true
  rescue Docker::Error::NotFoundError, Docker::Error::DockerError, Excon::Error => error
    say "Skipping local infra-network backfill: #{error.class}: #{error.message}"
    false
  end
end
