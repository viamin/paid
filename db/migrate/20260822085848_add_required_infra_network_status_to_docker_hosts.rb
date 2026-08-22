# frozen_string_literal: true

class AddRequiredInfraNetworkStatusToDockerHosts < ActiveRecord::Migration[8.1]
  PRIMARY_NETWORK_NAME = "paid_agent"
  UNKNOWN_STATUS = "unknown"

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
  end

  def down
    return unless column_exists?(:docker_hosts, :required_infra_network_status)

    remove_column :docker_hosts, :required_infra_network_status
  end
end
