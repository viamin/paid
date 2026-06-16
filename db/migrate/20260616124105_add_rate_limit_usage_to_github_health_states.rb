# frozen_string_literal: true

class AddRateLimitUsageToGithubHealthStates < ActiveRecord::Migration[8.1]
  def change
    add_column :github_health_states, :rate_limit_remaining, :integer
    add_column :github_health_states, :rate_limit_limit, :integer
    add_column :github_health_states, :rate_limit_reset_at, :datetime
    add_column :github_health_states, :rate_limit_observed_at, :datetime,
      comment: "When the remaining/limit rate-limit figures were last sampled from the GitHub API for this credential endpoint."
  end
end
