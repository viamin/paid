# frozen_string_literal: true

class AddLabelIntegrationModesToProjectsAndTenantSettings < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:projects, :label_integration_mode)
      add_column :projects, :label_integration_mode, :string, null: false, default: "read_write",
        comment: "Whether Paid writes GitHub labels: read_write, read_only, or ignored."
    end

    unless column_exists?(:tenant_settings, :default_label_integration_mode)
      add_column :tenant_settings, :default_label_integration_mode, :string, null: false, default: "read_write",
        comment: "Label integration mode assigned to newly created projects."
    end
  end
end
