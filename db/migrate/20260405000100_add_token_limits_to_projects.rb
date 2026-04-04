class AddTokenLimitsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :max_tokens_per_run, :integer, default: 10000000, null: false
    add_column :projects, :token_limit_warning_threshold, :integer, default: 5000000, null: false
  end
end
