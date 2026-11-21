# frozen_string_literal: true

class AddNativeTimeoutSecondsToPreCommitRequirements < ActiveRecord::Migration[8.1]
  def change
    add_column :pre_commit_requirements, :native_timeout_seconds, :integer, default: 300, null: false,
      comment: "Reviewed isolated native validation deadline; ordinary pre-commit and LLM deadlines are independent."
    add_check_constraint :pre_commit_requirements, "native_timeout_seconds BETWEEN 1 AND 900",
      name: "pre_commit_requirements_native_timeout_bounds", validate: false
  end
end
