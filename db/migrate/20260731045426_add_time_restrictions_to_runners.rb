# frozen_string_literal: true

class AddTimeRestrictionsToRunners < ActiveRecord::Migration[8.1]
  def change
    add_column :runners, :time_restrictions, :jsonb,
      comment: "Per-runner time-window usage restrictions. Null means no restrictions. " \
               "Shape: { mode: block|deprioritize, timezone: IANA zone, windows: [{ start_hour, end_hour }] }"
  end
end
