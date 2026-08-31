# frozen_string_literal: true

class AddNoCodeRequiredAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :no_code_required_at, :datetime,
      comment: "When non-null, an agent explicitly declared this issue's work complete without a code " \
        "change (no_code_required outcome). Permanently excludes the issue from auto-pick's " \
        "completed-issue recovery path even though paid_state is 'completed', so it does not loop back " \
        "into the queue on its own; only a manually triggered run can pick it up again."
  end
end
