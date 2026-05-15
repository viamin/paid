# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::Upsert, :no_db do
  let(:actor) { Struct.new(:name, :email).new("Current Editor", "editor@example.com") }
  let(:entry_class) do
    Struct.new(
      :name, :entry_type, :description, :provider, :provider_format, :usage_guidance,
      :team_scope, :status, :added_by_name, :added_by_email, :tags_csv, keyword_init: true
    ) do
      def assign_attributes(attributes)
        attributes.each { |key, value| public_send("#{key}=", value) }
      end
    end
  end
  let(:params) do
    {
      name: "Repo coding skill",
      entry_type: "skill",
      description: "Reusable coding instructions",
      provider: "claude",
      provider_format: "canonical_v1",
      usage_guidance: "Use on Rails issue runs.",
      team_scope: "account",
      status: "active",
      tags_csv: "rails, repo",
      added_by_name: "Original Publisher",
      added_by_email: "publisher@example.com"
    }
  end

  describe "#assign_metadata" do
    it "sets publisher provenance when the entry is first created" do
      entry = entry_class.new

      described_class.new(entry:, params:, actor:).send(:assign_metadata)

      expect(entry.added_by_name).to eq("Original Publisher")
      expect(entry.added_by_email).to eq("publisher@example.com")
    end

    it "preserves existing publisher provenance on later edits" do
      entry = entry_class.new(
        added_by_name: "Initial Publisher",
        added_by_email: "initial@example.com"
      )

      described_class.new(entry:, params:, actor:).send(:assign_metadata)

      expect(entry.added_by_name).to eq("Initial Publisher")
      expect(entry.added_by_email).to eq("initial@example.com")
    end
  end
end
