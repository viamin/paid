# frozen_string_literal: true

# Adds the RDR-066 human-led feature operating mode as a named project
# posture lever. Defaults to "standard" so existing projects are never
# silently enrolled — the column itself is the RDR's rollout-guard config
# gate. @spec FEATURE-APPROVAL-001
class AddOperatingModeToProjects < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:projects, :operating_mode)
      add_column :projects, :operating_mode, :string,
        default: "standard",
        null: false,
        comment: "Feature operating mode (RDR-066): standard | human_led_feature_factory"
    end
  end
end
