class AddDefaultMaxTokensPerRunToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :default_max_tokens_per_run, :integer, default: 10000000, null: false
  end
end
