# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260903034209_remove_pr_aggregation_enabled_from_projects")

RSpec.describe RemovePrAggregationEnabledFromProjects, :no_db do
  let(:migration) { described_class.new }

  describe "#up" do
    it "removes the column when it exists" do
      allow(migration).to receive(:table_exists?).with(:projects).and_return(true)
      allow(migration).to receive(:column_exists?).with(:projects, :pr_aggregation_enabled).and_return(true)
      allow(migration).to receive(:remove_column)

      migration.up

      expect(migration).to have_received(:remove_column)
        .with(:projects, :pr_aggregation_enabled, :boolean)
    end

    it "is a no-op when the projects table does not exist" do
      allow(migration).to receive(:table_exists?).with(:projects).and_return(false)
      allow(migration).to receive(:remove_column)

      migration.up

      expect(migration).not_to have_received(:remove_column)
    end

    it "is a no-op when the column has already been removed" do
      allow(migration).to receive(:table_exists?).with(:projects).and_return(true)
      allow(migration).to receive(:column_exists?).with(:projects, :pr_aggregation_enabled).and_return(false)
      allow(migration).to receive(:remove_column)

      migration.up

      expect(migration).not_to have_received(:remove_column)
    end
  end

  describe "#down" do
    it "re-adds the column with the original default: false and null: false contract" do
      allow(migration).to receive(:table_exists?).with(:projects).and_return(true)
      allow(migration).to receive(:column_exists?).with(:projects, :pr_aggregation_enabled).and_return(false)
      allow(migration).to receive(:add_column)

      migration.down

      expect(migration).to have_received(:add_column).with(
        :projects, :pr_aggregation_enabled, :boolean, default: false, null: false
      )
    end

    it "is a no-op when the projects table does not exist" do
      allow(migration).to receive(:table_exists?).with(:projects).and_return(false)
      allow(migration).to receive(:add_column)

      migration.down

      expect(migration).not_to have_received(:add_column)
    end

    it "is a no-op when the column already exists" do
      allow(migration).to receive(:table_exists?).with(:projects).and_return(true)
      allow(migration).to receive(:column_exists?).with(:projects, :pr_aggregation_enabled).and_return(true)
      allow(migration).to receive(:add_column)

      migration.down

      expect(migration).not_to have_received(:add_column)
    end
  end
end
