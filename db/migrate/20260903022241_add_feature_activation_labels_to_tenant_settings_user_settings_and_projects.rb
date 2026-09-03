class AddFeatureActivationLabelsToTenantSettingsUserSettingsAndProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :tenant_settings, :feature_activation_labels, :jsonb,
      comment: "Optional tenant-level override for per-item activation labels. Null means use built-in defaults."
    add_column :user_settings, :feature_activation_labels, :jsonb,
      comment: "Optional user-level override for per-item activation labels. Null means inherit tenant or built-in defaults."
    add_column :projects, :feature_activation_labels, :jsonb,
      comment: "Optional project-level override for per-item activation labels. Null means inherit user, tenant, or built-in defaults."
  end
end
