# frozen_string_literal: true

class UpdateLogidzeOnProjectsTrigger < ActiveRecord::Migration[8.1]
  def change
    update_trigger :logidze_on_projects,
      on: :projects,
      version: 2,
      revert_to_version: 1
  end
end
