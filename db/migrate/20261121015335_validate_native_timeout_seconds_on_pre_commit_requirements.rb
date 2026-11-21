# frozen_string_literal: true

class ValidateNativeTimeoutSecondsOnPreCommitRequirements < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :pre_commit_requirements, name: "pre_commit_requirements_native_timeout_bounds"
  end
end
