# frozen_string_literal: true

class AddProviderSelectionModeToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :provider_selection_mode, :string,
      limit: 20, default: "single", null: false
    add_column :user_settings, :provider_round_robin_state, :jsonb,
      default: {}, null: false

    add_check_constraint :user_settings,
      "provider_selection_mode IN ('single', 'round_robin', 'random')",
      name: "chk_provider_selection_mode"
  end
end
