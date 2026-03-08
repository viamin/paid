# frozen_string_literal: true

class ChangeAutoPickEnabledDefaultToFalse < ActiveRecord::Migration[8.1]
  def change
    change_column_default :projects, :auto_pick_enabled, from: true, to: false
  end
end
