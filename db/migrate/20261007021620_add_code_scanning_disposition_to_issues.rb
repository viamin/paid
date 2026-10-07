# frozen_string_literal: true

class AddCodeScanningDispositionToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :code_scanning_disposition, :string,
      comment: "Latest explicit upstream code-scanning disposition (for example fixed or dismissed)."
    add_column :issues, :code_scanning_disposition_reason, :text,
      comment: "Reason GitHub supplied for the latest code-scanning disposition."
    add_column :issues, :code_scanning_disposition_evidence, :jsonb,
      comment: "Bounded upstream evidence supporting the latest code-scanning disposition."
  end
end
