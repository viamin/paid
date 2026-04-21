# frozen_string_literal: true

class CreateBillingLineItems < ActiveRecord::Migration[8.1]
  def up
    create_billing_line_items unless table_exists?(:billing_line_items)

    add_foreign_key :billing_line_items, :billing_invoices unless foreign_key_exists?(:billing_line_items, :billing_invoices)
    add_index :billing_line_items, :billing_invoice_id unless index_exists?(:billing_line_items, :billing_invoice_id)
    add_index :billing_line_items, :line_item_type unless index_exists?(:billing_line_items, :line_item_type)
  end

  def down
    drop_table :billing_line_items, if_exists: true
  end

  private

  def create_billing_line_items
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
  end
end
