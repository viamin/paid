# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::Upsert, :no_db do
  let(:actor) { Struct.new(:name, :email).new("Current Editor", "editor@example.com") }
  let(:entry_class) do
    Struct.new(
      :name, :entry_type, :description, :provider, :provider_format, :usage_guidance,
      :extension_points, :certification_status, :support_tier, :documentation_url,
      :source_code_url, :certification_notes, :team_scope, :status, :added_by_name,
      :added_by_email, :tags_csv, keyword_init: true
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
      extension_points: [ "prompts", "tools" ],
      certification_status: "verified",
      support_tier: "partner",
      documentation_url: "https://docs.example.com/repo-coding-skill",
      source_code_url: "https://github.com/example/repo-coding-skill",
      certification_notes: "Reviewed against the Phase 8 ecosystem checklist.",
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

    it "normalizes ecosystem metadata onto the entry" do
      entry = entry_class.new

      described_class.new(entry:, params:, actor:).send(:assign_metadata)

      expect(entry.extension_points).to eq([ "prompts", "tools" ])
      expect(entry.certification_status).to eq("verified")
      expect(entry.support_tier).to eq("partner")
      expect(entry.documentation_url).to eq("https://docs.example.com/repo-coding-skill")
    end
  end

  describe "#upsert_rules!" do
    let(:entry_class) do
      stub_const("MarketplaceEntryUpsertNoDbEntry", Class.new do
        def marketplace_entry_rules; end
      end)
    end
    let(:rule_scope_class) do
      stub_const("MarketplaceEntryUpsertNoDbRuleScope", Class.new do
        def find_or_initialize_by(...)
        end
      end)
    end
    let(:entry) { instance_double(entry_class, marketplace_entry_rules: rule_scope) }
    let(:rule_scope) { instance_double(rule_scope_class) }

    before do
      allow(rule_scope).to receive(:find_or_initialize_by)
    end

    it "skips rule writes when no rule-management params were submitted" do
      service = described_class.new(entry:, params:, actor:)
      service.instance_variable_set(:@automatic_conditions, {})
      service.instance_variable_set(:@team_default_conditions, {})

      service.send(:upsert_rules!)

      expect(rule_scope).not_to have_received(:find_or_initialize_by)
    end
  end

  describe "#parsed_artifact_payloads" do
    let(:errors) { ActiveModel::Errors.new(entry) }
    let(:entry_class) do
      stub_const("MarketplaceEntryUpsertNoDbRenderableEntry", Class.new do
        attr_accessor :canonical_artifact_json, :renderers_json, :compatibility_constraints_json,
          :review_metadata_json, :automatic_conditions_json, :team_default_conditions_json

        def errors
          @errors ||= ActiveModel::Errors.new(self)
        end

        def read_attribute_for_validation(attribute)
          public_send(attribute)
        end

        def self.human_attribute_name(attribute, *)
          attribute.to_s.humanize
        end

        def self.lookup_ancestors
          [ self ]
        end
      end)
    end
    let(:entry) { entry_class.new }

    before do
      entry.canonical_artifact_json = JSON.generate(content: "Use the repo workflow.")
      entry.renderers_json = JSON.generate(claude: "oops")
      entry.compatibility_constraints_json = JSON.generate({})
      entry.review_metadata_json = JSON.generate({})
      entry.automatic_conditions_json = JSON.generate({})
      entry.team_default_conditions_json = JSON.generate({})
    end

    it "rejects provider renderer payloads that are not JSON objects" do
      result = described_class.new(entry:, params:, actor:).send(:parsed_artifact_payloads)

      expect(result).to be(false)
      expect(entry.errors[:renderers]).to include("must map provider keys to JSON objects (invalid: claude)")
    end
  end

  describe "#call" do
    it "merges nested validation errors onto the entry" do
      entry_model = Class.new do
        include ActiveModel::Model
      end.new
      nested_record = Class.new do
        include ActiveModel::Model
      end.new
      nested_record.errors.add(:base, "nested failure")
      service = described_class.new(entry: entry_model, params: {}, actor: nil)

      allow(service).to receive_messages(
        assign_metadata: nil,
        assign_virtual_fields: nil,
        parsed_artifact_payloads: true
      )
      allow(ActiveRecord::Base).to receive(:transaction).and_raise(ActiveRecord::RecordInvalid.new(nested_record))

      expect(service.call).to be(false)
      expect(entry_model.errors[:base]).to include("nested failure")
    end
  end

  describe "#parse_required_object" do
    let(:entry_class) do
      stub_const("MarketplaceEntryUpsertNoDbRequiredEntry", Class.new do
        attr_accessor :canonical_artifact_json

        def errors
          @errors ||= ActiveModel::Errors.new(self)
        end

        def read_attribute_for_validation(attribute)
          public_send(attribute)
        end

        def self.human_attribute_name(attribute, *)
          attribute.to_s.humanize
        end

        def self.lookup_ancestors
          [ self ]
        end
      end)
    end

    it "accepts an empty JSON object as a present canonical artifact" do
      entry = entry_class.new
      entry.canonical_artifact_json = JSON.generate({})

      parsed = described_class.new(entry:, params:, actor:).send(
        :parse_required_object,
        :canonical_artifact_json,
        :canonical_artifact
      )

      expect(parsed).to eq({})
      expect(entry.errors[:canonical_artifact]).to be_empty
    end
  end
end
