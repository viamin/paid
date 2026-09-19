# frozen_string_literal: true

class ValidateAppleVerificationWorkerConstraints < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :projects, name: "chk_projects_apple_verification_mode" if check_constraint_exists?(:projects, name: "chk_projects_apple_verification_mode")
  end

  def down
    # Validation does not create a separate schema object; the creating migration owns removal.
  end
end
