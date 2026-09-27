# frozen_string_literal: true

class AddLastScannerReconciledAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :last_scanner_reconciled_at, :datetime,
      comment: "Timestamp of the most recent SecurityAlerts::ProcessCodeScanningAlerts pass that " \
        "reconciled this synthetic code-scanning issue against the live alert list. Used to tell a " \
        "merged remediation PR (not yet verified) from a scanner-confirmed still-open/recurrent alert " \
        "(#4052)."
  end
end
