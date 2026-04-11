class AddDefaultAgentProvidersByGoalToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :default_agent_providers_by_goal, :jsonb, default: {}, null: false
  end
end
