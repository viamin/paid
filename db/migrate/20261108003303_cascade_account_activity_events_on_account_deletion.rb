class CascadeAccountActivityEventsOnAccountDeletion < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec PROJECT-DELEGATION-001
  def up
    create_function :protect_project_delegation_audit_event, version: 2
    replace_account_foreign_key(on_delete: :cascade)
  end

  def down
    create_function :protect_project_delegation_audit_event, version: 1
    replace_account_foreign_key
  end

  private

  def replace_account_foreign_key(on_delete: nil)
    safety_assured do
      remove_foreign_key :account_activity_events, :accounts
      add_foreign_key :account_activity_events, :accounts, on_delete: on_delete, validate: false
    end
    validate_foreign_key :account_activity_events, :accounts
  end
end
