# frozen_string_literal: true

class CreateDecisionRecordLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :decision_record_links do |t|
      t.references :decision_record, null: false, foreign_key: { on_delete: :cascade }
      t.string :linkable_type, limit: 100, null: false
      t.string :linkable_id, limit: 100, null: false
      t.string :link_type, limit: 50, null: false
      t.datetime :created_at, null: false
    end

    add_index :decision_record_links, [ :linkable_type, :linkable_id ]
  end
end
