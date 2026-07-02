# frozen_string_literal: true

class AddContainerMemoryLimitModeToUserSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :user_settings, :container_memory_limit_mode, :string,
      default: "manual",
      null: false,
      comment: "Whether agent container memory limits are taken from the fixed container_memory_bytes setting or from learned AgentRunResourceProfile recommendations."
    add_column :user_settings, :container_memory_auto_floor_bytes, :bigint,
      default: 512 * 1024 * 1024,
      null: false,
      comment: "Lower bound (bytes) for the auto-tuned agent container memory limit so a sparse profile does not underprovision runs."
    add_column :user_settings, :container_memory_auto_ceiling_bytes, :bigint,
      default: 16 * 1024 * 1024 * 1024,
      null: false,
      comment: "Upper bound (bytes) for the auto-tuned agent container memory limit so capacity-blocked workloads stop requesting unbounded memory."
  end
end
