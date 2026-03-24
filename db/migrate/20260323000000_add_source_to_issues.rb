# frozen_string_literal: true

class AddSourceToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :issues, :source, :string, default: "github", null: false unless column_exists?(:issues, :source)
    add_index :issues, :source, algorithm: :concurrently unless index_exists?(:issues, :source)
  end

  def down
    remove_index :issues, :source if index_exists?(:issues, :source)
    remove_column :issues, :source if column_exists?(:issues, :source)
  end
end
