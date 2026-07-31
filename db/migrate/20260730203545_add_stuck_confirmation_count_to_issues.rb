# frozen_string_literal: true

class AddStuckConfirmationCountToIssues < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:issues, :stuck_confirmation_count, :integer)

    add_column :issues, :stuck_confirmation_count, :integer,
      null: false,
      default: 0,
      comment: "Number of consecutive scans that observed this PR in an escalation-eligible " \
               "stuck state. Replaces the wall-clock no-progress window so Paid downtime " \
               "(which produces no scans) cannot drive false escalations."
  end
end
