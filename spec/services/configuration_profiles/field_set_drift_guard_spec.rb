# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::FieldSet do
  # This spec is the durable version of the coverage check enforced at profile
  # construction time. It exists so that adding a new operating-mode-relevant
  # flag to Project CANNOT silently leave profiles stale: the guard fails
  # loudly until every profile covers the new field (or the field is explicitly
  # declared out of scope in FieldSet).
  describe "profile coverage of the operating-mode field set" do
    let(:field_keys) { described_class.keys.map(&:to_s) }

    it "every registered profile covers exactly the field set" do
      ConfigurationProfiles::Registry.all.each do |profile|
        expect(profile.values.keys).to match_array(field_keys),
          lambda { "#{profile.key} must cover every field in FieldSet (#{field_keys - profile.values.keys} missing)" }
      end
    end

    it "constructing a profile with missing coverage raises" do
      expect {
        ConfigurationProfiles::Profile.new(
          key: :broken, name: "Broken", description: "incomplete",
          values: { "auto_pick_enabled" => false }
        )
      }.to raise_error(ArgumentError, /does not cover the operating-mode field set/)
    end
  end

  describe "field set stays in sync with the live schema" do
    let(:columns) { Project.columns_hash }

    it "every attribute field references a real projects column" do
      described_class.all.each do |field|
        next unless field.column

        expect(columns).to include(field.column),
          "#{field.key} maps to missing column #{field.column.inspect}"
      end
    end

    it "boolean attribute fields map to boolean columns" do
      described_class.all.each do |field|
        next unless field.kind == :boolean_attribute

        expect(columns[field.column].type).to eq(:boolean),
          "#{field.key} should reference a boolean column"
      end
    end

    it "enum attribute field options match the model's allowed values" do
      allowed = {
        "auto_merge_mode" => %w[off dependabot_only all],
        "merge_method" => Project::MERGE_METHODS,
        "auto_release_granularity" => Project::AUTO_RELEASE_GRANULARITIES
      }
      described_class.all.each do |field|
        next unless field.kind == :enum_attribute

        expect(field.options).to match_array(allowed.fetch(field.column)),
          "#{field.key} options drifted from #{field.column} allowed values"
      end
    end

    it "adoption_mode options match Project::ADOPTION_MODES" do
      field = described_class.lookup(:adoption_mode)
      expect(field.options).to match_array(Project::ADOPTION_MODES)
    end
  end

  describe "no operating-mode flag escapes profile coverage" do
    # Catches the original drift case: a developer adds an `auto_*` (or other
    # mode-relevant) column to projects without adding it to FieldSet. The
    # guard then fails until the field is either covered by profiles or
    # explicitly exempted in FieldSet::EXCLUDED_ATTRIBUTE_COLUMNS.
    let(:patterns) { described_class::MODE_RELEVANT_COLUMN_PATTERNS }
    let(:covered) { described_class.attribute_columns }
    let(:excluded) { described_class.excluded_attribute_columns }
    let(:accounted_for) { covered + excluded }

    it "every mode-relevant projects column is covered or explicitly excluded" do
      unaccounted = Project.columns_hash.keys.select do |column|
        patterns.any? { |pattern| pattern.is_a?(Regexp) ? pattern.match?(column) : column == pattern }
      end.reject { |column| accounted_for.include?(column) }

      expect(unaccounted).to be_empty,
        lambda {
          "These operating-mode columns lack profile coverage: #{unaccounted.inspect}. " \
          "Add them to ConfigurationProfiles::FieldSet (and cover them in every profile) " \
          "or, if they are not posture levers, exempt them in EXCLUDED_ATTRIBUTE_COLUMNS."
        }
    end

    it "every excluded column still exists on the projects table" do
      described_class::EXCLUDED_ATTRIBUTE_COLUMNS.each_key do |column|
        expect(Project.columns_hash).to include(column),
          "#{column} is exempted in FieldSet but no longer exists on projects"
      end
    end
  end

  describe "registry integrity" do
    it "profile keys are unique" do
      keys = ConfigurationProfiles::Registry.all.map(&:key)
      expect(keys).to eq(keys.uniq)
    end

    it "find! raises for unknown keys" do
      expect { ConfigurationProfiles::Registry.find!(:nope) }
        .to raise_error(ArgumentError, /Unknown configuration profile/)
    end
  end
end
