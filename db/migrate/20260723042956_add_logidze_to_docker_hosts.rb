# frozen_string_literal: true

class AddLogidzeToDockerHosts < ActiveRecord::Migration[8.1]
  def change
    add_column :docker_hosts, :log_data, :jsonb unless column_exists?(:docker_hosts, :log_data)

    reversible do |dir|
      dir.up do
        next if trigger_exists?(:docker_hosts, :logidze_on_docker_hosts)

        create_trigger :logidze_on_docker_hosts, on: :docker_hosts
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_docker_hosts" on "docker_hosts";
        SQL
      end
    end
  end
end
