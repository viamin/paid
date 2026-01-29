# frozen_string_literal: true

class ChangeProjectsPollIntervalDefault < ActiveRecord::Migration[8.1]
  def change
    change_column_default :projects, :poll_interval_seconds, from: 300, to: 60
  end
end
