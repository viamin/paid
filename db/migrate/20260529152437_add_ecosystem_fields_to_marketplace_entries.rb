# frozen_string_literal: true

class AddEcosystemFieldsToMarketplaceEntries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_column :marketplace_entries, :extension_points, :jsonb,
      null: false,
      default: [],
      comment: "Stable Paid extension points this entry targets, such as collectors or workflow strategies."
    add_column :marketplace_entries, :certification_status, :string,
      null: false,
      default: "uncertified",
      limit: 50,
      comment: "Certification state used to communicate ecosystem support expectations."
    add_column :marketplace_entries, :support_tier, :string,
      null: false,
      default: "community",
      limit: 50,
      comment: "Who supports the entry operationally: community, partner, or first-party."
    add_column :marketplace_entries, :documentation_url, :string,
      limit: 500,
      comment: "Primary documentation URL for installation and lifecycle guidance."
    add_column :marketplace_entries, :source_code_url, :string,
      limit: 500,
      comment: "Source repository or package URL for the extension payload."
    add_column :marketplace_entries, :certification_notes, :text,
      comment: "Operator-facing notes describing certification scope, evidence, or gaps."

    add_index :marketplace_entries, :extension_points, using: :gin, algorithm: :concurrently
    add_index :marketplace_entries, [ :account_id, :certification_status ],
      name: "idx_marketplace_entries_account_certification",
      algorithm: :concurrently
  end

  def down
    remove_index :marketplace_entries, name: "idx_marketplace_entries_account_certification", if_exists: true
    remove_index :marketplace_entries, :extension_points, if_exists: true

    remove_column :marketplace_entries, :certification_notes if column_exists?(:marketplace_entries, :certification_notes)
    remove_column :marketplace_entries, :source_code_url if column_exists?(:marketplace_entries, :source_code_url)
    remove_column :marketplace_entries, :documentation_url if column_exists?(:marketplace_entries, :documentation_url)
    remove_column :marketplace_entries, :support_tier if column_exists?(:marketplace_entries, :support_tier)
    remove_column :marketplace_entries, :certification_status if column_exists?(:marketplace_entries, :certification_status)
    remove_column :marketplace_entries, :extension_points if column_exists?(:marketplace_entries, :extension_points)
  end
end
