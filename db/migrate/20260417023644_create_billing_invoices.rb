# frozen_string_literal: true

class CreateBillingInvoices < ActiveRecord::Migration[8.1]
  def up
    create_billing_invoices unless table_exists?(:billing_invoices)

    add_foreign_key :billing_invoices, :accounts unless foreign_key_exists?(:billing_invoices, :accounts)
    add_foreign_key :billing_invoices, :billing_periods unless foreign_key_exists?(:billing_invoices, :billing_periods)
    add_index :billing_invoices, :account_id unless index_exists?(:billing_invoices, :account_id)
    add_index :billing_invoices, :billing_period_id unless index_exists?(:billing_invoices, :billing_period_id)
    add_external_id_index unless index_exists?(:billing_invoices, :external_id, name: "index_billing_invoices_on_external_id")
    add_index :billing_invoices, [ :account_id, :status ] unless index_exists?(:billing_invoices, [ :account_id, :status ])
  end

  def down
    drop_table :billing_invoices, if_exists: true
  end

  private

  def create_billing_invoices
    create_table :billing_invoices do |t|
      t.references :account, null: false
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
  end

  def add_external_id_index
    add_index :billing_invoices, :external_id, unique: true, where: "external_id IS NOT NULL"
  end
end
