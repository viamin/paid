# frozen_string: true

class AddSeedOwnerToAccounts < ActiveRecord::Migration[8.1]
  # @spec LIVE-PREVIEW-012
  def change
    add_column :accounts, :seed_owner, :string,
      comment: "Seed tool that owns this account (paid-journey); NULL for accounts not created by a seed tool."
  end
end
