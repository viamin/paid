# frozen_string_literal: true

# @spec AUTO-PICK-QUEUE-015
class AddDeclarationProvenanceToIssueDependencies < ActiveRecord::Migration[8.1]
  def change
    add_column :issue_dependencies, :declaration_source, :string,
      comment: "GitHub surface containing the effective dependency declaration."
    add_column :issue_dependencies, :declaration_url, :string,
      comment: "GitHub URL for the effective dependency declaration when available."
  end
end
