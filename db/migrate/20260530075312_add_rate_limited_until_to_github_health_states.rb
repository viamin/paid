# frozen_string_literal: true

class AddRateLimitedUntilToGithubHealthStates < ActiveRecord::Migration[8.1]
  def change
    add_column :github_health_states,
               :rate_limited_until,
               :datetime,
               comment: "Timestamp at which the GitHub API rate limit is expected to reset. While this is in the future the endpoint is treated as unavailable so the queue scheduler pauses dispatching."
  end
end
