# frozen_string_literal: true

class AddUniqueIndexToDecisionRecordLinks < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :decision_record_links,
              %i[decision_record_id linkable_type linkable_id link_type],
              unique: true,
              name: "index_decision_record_links_on_record_and_linkable_and_type",
              algorithm: :concurrently
  end

  def down
    remove_index :decision_record_links,
                 name: "index_decision_record_links_on_record_and_linkable_and_type",
                 if_exists: true,
                 algorithm: :concurrently
  end
end
