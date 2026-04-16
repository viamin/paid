# frozen_string_literal: true

class AddSchedulerPausedAtToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :scheduler_paused_at, :datetime
  end
end
