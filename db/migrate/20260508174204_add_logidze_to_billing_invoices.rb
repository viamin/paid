# frozen_string_literal: true

class AddLogidzeToBillingInvoices < ActiveRecord::Migration[8.1]
  def change
    add_column :billing_invoices, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_billing_invoices, on: :billing_invoices
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_billing_invoices" on "billing_invoices";
        SQL
      end
    end
  end
end
