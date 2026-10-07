# frozen_string_literal: true

class AddCodeScanningCoverageToProjects < ActiveRecord::Migration[8.1]
  COLUMNS = {
    last_code_scanning_scan_attempted_at: [ :datetime,
      "Timestamp of the most recent request to fetch code-scanning alerts. This is distinct from the last complete successful snapshot." ],
    code_scanning_scan_error_kind: [ :string,
      "Current code-scanning coverage failure classification: disabled, not_configured, permission, rate_limited, or transient." ],
    code_scanning_scan_error_reason: [ :string,
      "Sanitized explanation of the current code-scanning coverage failure." ],
    next_code_scanning_scan_at: [ :datetime,
      "Earliest time a failed code-scanning fetch may be retried." ]
  }.freeze

  def up
    return unless table_exists?(:projects)

    COLUMNS.each do |name, (type, comment)|
      add_column :projects, name, type, comment: comment unless column_exists?(:projects, name)
    end
  end

  def down
    return unless table_exists?(:projects)

    COLUMNS.each_key do |name|
      remove_column :projects, name if column_exists?(:projects, name)
    end
  end
end
