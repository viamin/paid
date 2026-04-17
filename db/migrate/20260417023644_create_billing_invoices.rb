# frozen_string_literal: true

class CreateBillingInvoices < ActiveRecord::Migration[8.1]
  def change
    create_table :billing_invoices do |t|
      t.references :account, null: false, foreign_key: true
      t.references :billing_period, null: false, foreign_key: true
      t.string :external_id, limit: 255
      t.string :status, null: false, limit: 20, default: "draft"
      t.integer :subtotal_cents, null: false, default: 0
      t.integer :tax_cents, null: false, default: 0
      t.integer :total_cents, null: false, default: 0
      t.datetime :issued_at
      t.datetime :due_at
      t.datetime :paid_at
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :billing_invoices, :external_id, unique: true, where: "external_id IS NOT NULL"
    add_index :billing_invoices, [ :account_id, :status ]
  end
end
