# frozen_string_literal: true

class AddSourceToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :source, :string, default: "github", null: false
    add_index :issues, :source
  end
end
