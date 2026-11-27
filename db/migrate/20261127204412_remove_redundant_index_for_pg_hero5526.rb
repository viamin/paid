# frozen_string_literal: true

# index_docker_hosts_on_account_id_and_identifier covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5526 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :docker_hosts, name: "index_docker_hosts_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :docker_hosts, [ :account_id ],
      name: "index_docker_hosts_on_account_id", algorithm: :concurrently
  end
end
