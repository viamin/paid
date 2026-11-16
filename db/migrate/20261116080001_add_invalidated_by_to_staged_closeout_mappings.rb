# frozen_string_literal: true

class AddInvalidatedByToStagedCloseoutMappings < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_reference :staged_closeout_mappings, :invalidated_by, index: {algorithm: :concurrently}
  end
end
