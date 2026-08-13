# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260515011327_add_marketplace_auto_attach_enabled_to_user_settings")

RSpec.describe AddMarketplaceAutoAttachEnabledToUserSettings, :no_db do
  let(:migration) { described_class.new }

  it "adds a non-null marketplace auto-attach consent column with a false default" do
    allow(migration).to receive(:add_column)

    migration.change

    expect(migration).to have_received(:add_column).with(
      :user_settings,
      :marketplace_auto_attach_enabled,
      :boolean,
      default: false,
      null: false,
      comment: "Whether this user opts their own agent runs into automatic and team-default marketplace attachments."
    )
  end
end
