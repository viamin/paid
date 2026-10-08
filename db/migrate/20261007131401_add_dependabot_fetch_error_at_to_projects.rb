# frozen_string_literal: true

class AddDependabotFetchErrorAtToProjects < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:projects, :dependabot_fetch_error_at)

    add_column :projects, :dependabot_fetch_error_at, :datetime,
      comment: "Timestamp of the most recent transient Dependabot fetch failure. Used to back off retries without blocking code-scanning coverage."
  end
end
