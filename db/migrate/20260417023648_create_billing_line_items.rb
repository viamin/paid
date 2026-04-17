# frozen_string_literal: true

class CreateBillingLineItems < ActiveRecord::Migration[8.1]
  def change
    create_table :billing_line_items do |t|
      t.references :billing_invoice, null: false, foreign_key: true
      t.string :description, null: false
      t.string :line_item_type, null: false, limit: 30
      t.decimal :quantity, precision: 18, scale: 4, null: false, default: 0
      t.integer :unit_price_cents, null: false, default: 0
      t.integer :total_cents, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :billing_line_items, :line_item_type
  end
end
