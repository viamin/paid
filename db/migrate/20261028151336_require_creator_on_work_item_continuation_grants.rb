# frozen_string_literal: true

class RequireCreatorOnWorkItemContinuationGrants < ActiveRecord::Migration[8.1]
  def change
    add_check_constraint :work_item_continuation_grants, "created_by_id IS NOT NULL",
      name: "work_item_continuation_grants_created_by_id_null", validate: false
  end
end
