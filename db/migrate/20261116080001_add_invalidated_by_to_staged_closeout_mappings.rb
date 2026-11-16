# frozen_string_literal: true

require_relative "20261116080000_create_staged_closeout_adoption"

class AddInvalidatedByToStagedCloseoutMappings < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_reference :staged_closeout_mappings, :invalidated_by, index: { algorithm: :concurrently }
    refresh_tenant_policy
  end

  def down
    CreateStagedCloseoutAdoption.new.disable_tenant_rls
    remove_reference :staged_closeout_mappings, :invalidated_by, index: { algorithm: :concurrently }
    CreateStagedCloseoutAdoption.new.enable_tenant_rls
  end

  private

  def refresh_tenant_policy
    policy_migration = CreateStagedCloseoutAdoption.new
    policy_migration.disable_tenant_rls
    policy_migration.enable_tenant_rls
  end
end
