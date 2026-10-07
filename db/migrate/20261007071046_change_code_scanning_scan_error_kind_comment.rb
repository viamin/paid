# frozen_string_literal: true

class ChangeCodeScanningScanErrorKindComment < ActiveRecord::Migration[8.1]
  COMMENT = "Current code-scanning coverage failure classification: not_configured, permission, rate_limited, or transient."
  PREVIOUS_COMMENT = "Current code-scanning coverage failure classification: disabled, not_configured, permission, rate_limited, or transient."

  def up
    return unless column_exists?(:projects, :code_scanning_scan_error_kind)

    change_column_comment :projects, :code_scanning_scan_error_kind, COMMENT
  end

  def down
    return unless column_exists?(:projects, :code_scanning_scan_error_kind)

    change_column_comment :projects, :code_scanning_scan_error_kind, PREVIOUS_COMMENT
  end
end
