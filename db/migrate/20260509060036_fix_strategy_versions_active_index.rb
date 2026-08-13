# frozen_string_literal: true

class FixStrategyVersionsActiveIndex < ActiveRecord::Migration[8.1]
  def up
    remove_index :strategy_versions, name: "index_strategy_versions_one_active_per_strategy", if_exists: true
    add_index :strategy_versions, :strategy_id,
      unique: true,
      where: "promotion_state = 'active' AND retired_at IS NULL",
      name: "index_strategy_versions_one_active_per_strategy",
      if_not_exists: true
  end

  def down
    remove_index :strategy_versions, name: "index_strategy_versions_one_active_per_strategy", if_exists: true
    add_index :strategy_versions, :strategy_id,
      unique: true,
      where: "promotion_state = 'active'",
      name: "index_strategy_versions_one_active_per_strategy",
      if_not_exists: true
  end
end
