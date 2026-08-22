# frozen_string_literal: true

class AddRequiredInfraNetworkStatusToDockerHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :docker_hosts, :required_infra_network_status, :string, null: false, default: "unknown",
      comment: "Whether the unrestricted paid_internal Docker network (subscription-auth/direct-outbound runs) exists on the host."
  end
end
