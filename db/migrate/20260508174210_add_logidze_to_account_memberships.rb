# frozen_string_literal: true

class AddLogidzeToAccountMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :account_memberships, :log_data, :jsonb

    reversible do |dir|
      dir.up do
        create_trigger :logidze_on_account_memberships, on: :account_memberships
      end

      dir.down do
        execute <<~SQL
          DROP TRIGGER IF EXISTS "logidze_on_account_memberships" on "account_memberships";
        SQL
      end
    end
  end
end
