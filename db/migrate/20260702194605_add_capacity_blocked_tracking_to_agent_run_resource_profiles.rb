# frozen_string_literal: true

class AddCapacityBlockedTrackingToAgentRunResourceProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_run_resource_profiles, :capacity_blocked, :boolean,
      default: false,
      null: false,
      comment: "True when the profile has hit the configured memory ceiling while still OOM-killing runs. Further limit growth is paused until Docker capacity or the ceiling increases."
    add_column :agent_run_resource_profiles, :capacity_blocked_at, :datetime,
      comment: "When the profile first transitioned into capacity_blocked. Nil while the profile remains unblocked."
    add_column :agent_run_resource_profiles, :consecutive_low_memory_samples, :integer,
      default: 0,
      null: false,
      comment: "Counter of consecutive successful samples where observed peak stayed well below the recommended limit. Required before any downward tuning, to prevent oscillation."
    add_column :agent_run_resource_profiles, :downward_tuning_count, :integer,
      default: 0,
      null: false,
      comment: "Total number of times the profile has been downward-tuned. Useful for debugging anti-oscillation behavior."
  end
end