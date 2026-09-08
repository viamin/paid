# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260908080512_drop_pr_aggregation_enabled_from_projects")

RSpec.describe DropPrAggregationEnabledFromProjects, :no_db do
  let(:migration) { described_class.new }

  describe "#up" do
    it "drops pr_aggregation_enabled when the column is present" do
      allow(migration).to receive(:column_exists?).with(:projects, :pr_aggregation_enabled).and_return(true)
      allow(migration).to receive(:remove_column)

      migration.up

      expect(migration).to have_received(:remove_column).with(:projects, :pr_aggregation_enabled)
    end

    it "is a no-op when the column was already dropped" do
      allow(migration).to receive(:column_exists?).with(:projects, :pr_aggregation_enabled).and_return(false)
      allow(migration).to receive(:remove_column)

      migration.up

      expect(migration).not_to have_received(:remove_column)
    end
  end

  describe "#down" do
    it "recreates pr_aggregation_enabled with the original defaults when missing" do
      allow(migration).to receive(:column_exists?).with(:projects, :pr_aggregation_enabled).and_return(false)
      allow(migration).to receive(:add_column)

      migration.down

      expect(migration).to have_received(:add_column).with(
        :projects, :pr_aggregation_enabled, :boolean, default: false, null: false
      )
    end

    it "is a no-op when the column already exists" do
      allow(migration).to receive(:column_exists?).with(:projects, :pr_aggregation_enabled).and_return(true)
      allow(migration).to receive(:add_column)

      migration.down

      expect(migration).not_to have_received(:add_column)
    end
  end
end
