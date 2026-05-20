# frozen_string_literal: true

class AddConventionResolutionFieldsToProjectConventions < ActiveRecord::Migration[8.1]
  def change
    add_column :project_convention_detections, :category, :string,
      comment: "Typed convention category, such as commit_convention_policy or hook_system."
    add_column :project_convention_overrides, :category, :string,
      comment: "Typed convention category, such as commit_convention_policy or hook_system."
    add_column :project_convention_overrides, :mode, :string,
      default: "apply", null: false,
      comment: "Override handling policy: apply, warn, or ignore."

    safety_assured do
      up_only do
        execute <<~SQL.squish
          UPDATE project_convention_detections
          SET category = CASE key
            WHEN 'release_automation' THEN 'release_automation'
            WHEN 'commit_style' THEN 'commit_convention_policy'
            WHEN 'pr_title_style' THEN 'pr_title_policy'
            WHEN 'hook_manager' THEN 'hook_system'
            WHEN 'issue_dependency_format' THEN 'issue_dependency_wording'
            WHEN 'ci_entrypoint' THEN 'ci_entrypoints'
            ELSE 'custom'
          END
        SQL

        execute <<~SQL.squish
          UPDATE project_convention_overrides
          SET category = CASE key
            WHEN 'release_automation' THEN 'release_automation'
            WHEN 'commit_style' THEN 'commit_convention_policy'
            WHEN 'pr_title_style' THEN 'pr_title_policy'
            WHEN 'hook_manager' THEN 'hook_system'
            WHEN 'issue_dependency_format' THEN 'issue_dependency_wording'
            WHEN 'ci_entrypoint' THEN 'ci_entrypoints'
            ELSE 'custom'
          END,
          mode = CASE enabled
            WHEN TRUE THEN 'apply'
            ELSE 'ignore'
          END
        SQL
      end
    end
  end
end
