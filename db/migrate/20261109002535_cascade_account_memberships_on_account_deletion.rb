# frozen_string_literal: true

class CascadeAccountMembershipsOnAccountDeletion < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # Fixture replay and database-level cleanup may delete an account without
  # instantiating its associations. Keep that path consistent with Account's
  # dependent-destroy contract and avoid relying on superuser-only trigger
  # disabling in the non-superuser CI runtime role.
  #
  # @spec PROJECT-DELEGATION-001
  def up
    replace_account_foreign_key(on_delete: :cascade)
  end

  def down
    replace_account_foreign_key
  end

  private

  def replace_account_foreign_key(on_delete: nil)
    safety_assured do
      remove_foreign_key :account_memberships, :accounts
      add_foreign_key :account_memberships, :accounts, on_delete: on_delete, validate: false
    end
    validate_foreign_key :account_memberships, :accounts
  end
end
