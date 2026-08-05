# frozen_string_literal: true

module ConfigurationProfiles
  # Compatibility facade over the chat-integrated Configuration::Profiles
  # registry. The canonical operating-mode field definitions now live in
  # Configuration::Profiles::Settings so the chat planner/applier path and the
  # legacy posture helpers read the same source of truth.
  module FieldSet
    # Describes one operating-mode-relevant setting on a {::Project}.
    #
    # +kind+ drives how the value is read from / written to the project:
    # [+boolean_attribute+] a NOT NULL boolean column named by +column+
    # [+enum_attribute+]     a string column named by +column+ constrained to +options+
    # [+adoption_mode+]      +interop_settings["adoption_mode"]+ (gradual-adoption posture)
    # [+review_method+]      the +enabled+ flag of a review method named by +method+
    # [+quality_gate+]       +quality_gate_settings["enabled"]+
    class Field < Data.define(:key, :kind, :label, :column, :options, :method)
      def initialize(key:, kind:, label:, column: nil, options: nil, method: nil)
        super
      end

      def boolean? = kind == :boolean_attribute

      def enum? = kind == :enum_attribute
    end

    FIELDS = Configuration::Profiles::Settings.target_descriptors.map do |descriptor|
      Field.new(
        key: descriptor.key.to_sym,
        kind: descriptor.kind,
        label: descriptor.label,
        column: descriptor.column,
        options: descriptor.options,
        method: descriptor.method_name
      )
    end.freeze

    MODE_RELEVANT_COLUMN_PATTERNS = Configuration::Profiles::Settings::MODE_RELEVANT_COLUMN_PATTERNS
    EXCLUDED_ATTRIBUTE_COLUMNS = Configuration::Profiles::Settings::EXCLUDED_ATTRIBUTE_COLUMNS

    class << self
      def all = FIELDS

      def keys = FIELDS.map(&:key).freeze

      def lookup(key)
        FIELDS.find { |field| field.key == key.to_sym } ||
          raise(ArgumentError, "Unknown configuration profile field: #{key.inspect}")
      end

      # Operating-mode-relevant columns that live directly on the +projects+
      # table. The drift guard cross-checks this against the live schema so a
      # newly added automation column cannot slip in without explicit coverage.
      def attribute_columns
        FIELDS.filter_map { |field| field.column if field.column }
      end

      def excluded_attribute_columns = EXCLUDED_ATTRIBUTE_COLUMNS.keys.freeze

      def read(project, key)
        Configuration::Profiles::Settings.read(project, key)
      end

      def write(project, key, value)
        Configuration::Profiles::Settings.write(project, key, value)
      end

      # Reads every field into a {String} => value hash. Used for snapshots,
      # posture matching, and activity audit metadata.
      def snapshot(project)
        Configuration::Profiles::Settings.snapshot(project).transform_keys(&:to_s)
      end

      # Values considered "equivalent" for posture matching — normalizes
      # strings/booleans so +true+ vs +"true"+ and +"off"+ vs +false+ (for
      # auto-merge posture) don't create spurious mismatches.
      def equivalent?(left, right)
        Configuration::Profiles::Settings.equivalent?(left, right)
      end
    end
  end
end
