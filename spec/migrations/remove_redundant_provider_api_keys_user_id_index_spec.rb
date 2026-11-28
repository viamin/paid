# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20261128095755_remove_redundant_provider_api_keys_user_id_index")

RSpec.describe RemoveRedundantProviderApiKeysUserIdIndex, :no_db do
  let(:migration) { described_class.new }

  # @spec POSTGRESQL-PERSISTENCE-014
  it "removes only the redundant user lookup index concurrently and restores it on rollback" do
    expect(described_class.disable_ddl_transaction).to be true
    allow(migration).to receive(:remove_index)
    allow(migration).to receive(:add_index)

    migration.up

    expect(migration).to have_received(:remove_index).with(
      :provider_api_keys,
      name: "index_provider_api_keys_on_user_id",
      algorithm: :concurrently
    )

    migration.down

    expect(migration).to have_received(:add_index).with(
      :provider_api_keys,
      :user_id,
      name: "index_provider_api_keys_on_user_id",
      algorithm: :concurrently
    )
  end
end
