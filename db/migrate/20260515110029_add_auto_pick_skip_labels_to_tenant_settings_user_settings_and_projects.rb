# frozen_string_literal: true

class AddAutoPickSkipLabelsToTenantSettingsUserSettingsAndProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :tenant_settings, :auto_pick_skip_labels, :jsonb,
      comment: "Optional tenant-level override for labels that make auto-pick skip an issue. Null means use built-in defaults."
    add_column :user_settings, :auto_pick_skip_labels, :jsonb,
      comment: "Optional user-level override for labels that make auto-pick skip an issue. Null means inherit tenant or built-in defaults."
    add_column :projects, :auto_pick_skip_labels, :jsonb,
      comment: "Optional project-level override for labels that make auto-pick skip an issue. Null means inherit user, tenant, or built-in defaults."
  end
end
