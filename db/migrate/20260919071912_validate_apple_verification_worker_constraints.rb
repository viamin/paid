# frozen_string_literal: true

class ValidateAppleVerificationWorkerConstraints < ActiveRecord::Migration[8.1]
  def change
    validate_check_constraint :projects, name: "chk_projects_apple_verification_mode" if check_constraint_exists?(:projects, name: "chk_projects_apple_verification_mode")
  end
end
