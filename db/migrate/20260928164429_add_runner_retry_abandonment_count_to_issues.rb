# frozen_string_literal: true

class AddRunnerRetryAbandonmentCountToIssues < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:issues, :runner_retry_abandonment_count)

    add_column :issues, :runner_retry_abandonment_count, :integer, default: 0, null: false,
      comment: "Number of times this item has entered retry-limited abandonment."
  end
end
