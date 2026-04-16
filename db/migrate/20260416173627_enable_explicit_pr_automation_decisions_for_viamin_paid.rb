# frozen_string_literal: true

# Rollout: enable :explicit_pr_automation_decisions for the viamin/paid project.
# Idempotent; safe to run on environments that do not have a viamin/paid project
# (dev/CI/fresh installs) — in that case the migration is a no-op.
class EnableExplicitPrAutomationDecisionsForViaminPaid < ActiveRecord::Migration[8.1]
  FLAG = :explicit_pr_automation_decisions
  TARGET_OWNER = "viamin"
  TARGET_REPO = "paid"

  class MigrationProject < ApplicationRecord
    self.table_name = "projects"

    def flipper_id
      "Project;#{id}"
    end
  end

  def up
    projects = MigrationProject.unscoped.where(owner: TARGET_OWNER, repo: TARGET_REPO)
    if projects.none?
      say "No #{TARGET_OWNER}/#{TARGET_REPO} project present; skipping #{FLAG} enablement"
      return
    end

    projects.find_each do |project|
      FeatureFlags.enable!(FLAG, project: project)
      say "Enabled #{FLAG} for project #{project.id} (#{TARGET_OWNER}/#{TARGET_REPO})"
    end
  end

  def down
    projects = MigrationProject.unscoped.where(owner: TARGET_OWNER, repo: TARGET_REPO)
    projects.find_each do |project|
      FeatureFlags.disable!(FLAG, project: project)
      say "Disabled #{FLAG} for project #{project.id} (#{TARGET_OWNER}/#{TARGET_REPO})"
    end
  end
end
