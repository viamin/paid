# frozen_string_literal: true

class AddCloseoutClosingAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :closeout_closing_at, :datetime,
      comment: "When a remote GitHub close is in flight and continuation admission is revoked"
  end
end
