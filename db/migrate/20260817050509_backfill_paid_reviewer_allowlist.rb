# frozen_string_literal: true

class BackfillPaidReviewerAllowlist < ActiveRecord::Migration[8.1]
  PAID_AGENT_REVIEW_BOT_ALLOWLIST_LOGINS = %w[paid-code-reviewer[bot]].freeze

  class MigrationProject < ApplicationRecord
    self.table_name = "projects"
  end

  def up
    TenantContext.with_system_access do
      MigrationProject.unscoped.find_each do |project|
        next unless paid_agent_review_enabled?(project.review_settings)

        allowed = Array(project.allowed_github_usernames).filter_map { |login| login.to_s.presence }
        allowed_downcased = allowed.map(&:downcase)
        additions = PAID_AGENT_REVIEW_BOT_ALLOWLIST_LOGINS.reject { |login| allowed_downcased.include?(login.downcase) }
        next if additions.empty?

        project.update_columns(allowed_github_usernames: allowed + additions, updated_at: Time.current)
      end
    end
  end

  def down; end

  private

  def paid_agent_review_enabled?(settings)
    return false unless settings.is_a?(Hash)

    normalized = settings.deep_stringify_keys
    normalized["enabled"] == true && normalized.dig("methods", "paid_agent", "enabled") == true
  end
end
