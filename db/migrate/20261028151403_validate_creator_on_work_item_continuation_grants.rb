# frozen_string_literal: true

class ValidateCreatorOnWorkItemContinuationGrants < ActiveRecord::Migration[8.1]
  CONSTRAINT = "work_item_continuation_grants_created_by_id_null"

  def up
    validate_check_constraint :work_item_continuation_grants, name: CONSTRAINT
    change_column_null :work_item_continuation_grants, :created_by_id, false
    remove_check_constraint :work_item_continuation_grants, name: CONSTRAINT
  end

  def down
    add_check_constraint :work_item_continuation_grants, "created_by_id IS NOT NULL",
      name: CONSTRAINT, validate: false
    change_column_null :work_item_continuation_grants, :created_by_id, true
  end
end
