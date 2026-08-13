class AddRelationshipsParsedAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :relationships_parsed_at, :datetime
    add_index :issues, :relationships_parsed_at
  end
end
