# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260819232912_correct_provisioning_intents_table_comment")

RSpec.describe CorrectProvisioningIntentsTableComment, :no_db do
  let(:migration) { described_class.new }
  let(:correct_comment) { described_class::CORRECT_TABLE_COMMENT }
  let(:legacy_comment) { described_class::LEGACY_TABLE_COMMENT }

  it "rewrites the provisioning_intents table comment on existing databases" do
    allow(migration).to receive(:table_exists?).with(:provisioning_intents).and_return(true)
    allow(migration).to receive(:change_table_comment)

    migration.up

    expect(migration).to have_received(:change_table_comment)
      .with(:provisioning_intents, correct_comment)
  end

  it "skips rewriting when the provisioning_intents table does not exist" do
    allow(migration).to receive(:table_exists?).with(:provisioning_intents).and_return(false)
    allow(migration).to receive(:change_table_comment)

    migration.up

    expect(migration).not_to have_received(:change_table_comment)
  end

  it "reverts the table comment on down so a rolled-back schema dump matches the original migration" do
    allow(migration).to receive(:table_exists?).with(:provisioning_intents).and_return(true)
    allow(migration).to receive(:change_table_comment)

    migration.down

    expect(migration).to have_received(:change_table_comment)
      .with(:provisioning_intents, legacy_comment)
  end

  it "skips the revert when the provisioning_intents table does not exist" do
    allow(migration).to receive(:table_exists?).with(:provisioning_intents).and_return(false)
    allow(migration).to receive(:change_table_comment)

    migration.down

    expect(migration).not_to have_received(:change_table_comment)
  end
end
