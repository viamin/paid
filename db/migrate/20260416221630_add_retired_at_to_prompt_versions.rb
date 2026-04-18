# frozen_string_literal: true

class AddRetiredAtToPromptVersions < ActiveRecord::Migration[8.1]
  def change
    add_column :prompt_versions, :retired_at, :datetime
    add_index :prompt_versions, :retired_at
  end
end
