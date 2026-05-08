# frozen_string_literal: true

class AddLogidzeToBillingPlans < ActiveRecord::Migration[8.1]
  def change
    add_column :billing_plans, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_billing_plans, on: :billing_plans
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_billing_plans" on "billing_plans";
        SQL
      end
    end
  end
end
