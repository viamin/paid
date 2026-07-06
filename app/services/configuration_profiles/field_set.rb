# frozen_string_literal: true

module ConfigurationProfiles
  # Canonical registry of the project-level settings that define an operating
  # mode (a "posture"). This is the single source of truth that the drift
  # regression guard, planner, applier, posture describer, and rollback helper
  # all operate against.
  #
  # Adding a new automation flag to {::Project} that should influence operating
  # mode means adding a {Field} here AND covering it in every profile in
  # {Registry}. The drift guard spec fails loudly otherwise.
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

    FIELDS = [
      Field.new(key: :auto_pick_enabled, kind: :boolean_attribute, column: "auto_pick_enabled",
                label: "Auto-pick issues"),
      Field.new(key: :auto_scan_prs, kind: :boolean_attribute, column: "auto_scan_prs",
                label: "Auto-continue (scan PRs)"),
      Field.new(key: :automation_on_label_enabled, kind: :boolean_attribute, column: "automation_on_label_enabled",
                label: "Run automation on label"),
      Field.new(key: :auto_merge_mode, kind: :enum_attribute, column: "auto_merge_mode",
                options: %w[off dependabot_only all], label: "Auto-merge mode"),
      Field.new(key: :auto_fix_merge_conflicts, kind: :boolean_attribute, column: "auto_fix_merge_conflicts",
                label: "Auto-fix merge conflicts"),
      Field.new(key: :merge_method, kind: :enum_attribute, column: "merge_method",
                options: %w[squash merge rebase], label: "Merge method"),
      Field.new(key: :auto_release_granularity, kind: :enum_attribute, column: "auto_release_granularity",
                options: %w[off patch_only minor_only major_only all], label: "Auto-release granularity"),
      Field.new(key: :auto_enhance_enabled, kind: :boolean_attribute, column: "auto_enhance_enabled",
                label: "Auto-enhance before PR"),
      Field.new(key: :auto_add_labels_enabled, kind: :boolean_attribute, column: "auto_add_labels_enabled",
                label: "Auto-add labels"),
      Field.new(key: :pr_aggregation_enabled, kind: :boolean_attribute, column: "pr_aggregation_enabled",
                label: "Aggregate decomposed PRs"),
      Field.new(key: :auto_scan_security, kind: :boolean_attribute, column: "auto_scan_security",
                label: "Auto-scan security alerts"),
      Field.new(key: :knowledge_evolution_enabled, kind: :boolean_attribute, column: "knowledge_evolution_enabled",
                label: "Knowledge evolution"),
      Field.new(key: :allow_bot_authored_pr_auto_merge, kind: :boolean_attribute,
                column: "allow_bot_authored_pr_auto_merge", label: "Allow bot-authored PR auto-merge"),
      Field.new(key: :adoption_mode, kind: :adoption_mode,
                options: ::Project::ADOPTION_MODES, label: "Adoption mode"),
      Field.new(key: :review_paid_agent, kind: :review_method, method: "paid_agent",
                label: "Paid-agent review"),
      Field.new(key: :review_copilot, kind: :review_method, method: "copilot",
                label: "Copilot review"),
      Field.new(key: :quality_gate_enabled, kind: :quality_gate,
                label: "Quality gate")
    ].freeze

    # Column-name patterns that mark a +projects+ column as operating-mode
    # relevant. Any column matching one of these must either be covered by a
    # {Field} above or be explicitly listed in {EXCLUDED_ATTRIBUTE_COLUMNS}
    # (with a justification). This is what makes the drift guard fail loudly
    # the moment a new automation flag lands without profile coverage.
    MODE_RELEVANT_COLUMN_PATTERNS = [
      /\Aauto_/,
      /_enabled\z/,
      "automation_on_label_enabled",
      "pr_aggregation_enabled",
      "allow_bot_authored_pr_auto_merge",
      "merge_method"
    ].freeze

    # Columns that match {MODE_RELEVANT_COLUMN_PATTERNS} but are deliberately
    # not operating-mode levers, so they are exempt from profile coverage.
    # Add a comment explaining why whenever you extend this list.
    EXCLUDED_ATTRIBUTE_COLUMNS = {
      # A JSONB label allowlist, not an on/off posture lever.
      "auto_pick_skip_labels" => "label override, not an automation toggle",
      # A git-credential fallback mechanism, unrelated to operating posture.
      "git_push_pat_fallback_enabled" => "credential fallback, not an automation toggle"
    }.freeze

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
        field = lookup(key)
        case field.kind
        when :boolean_attribute then project.public_send(field.column) == true
        when :enum_attribute     then project.public_send(field.column)
        when :adoption_mode      then project.adoption_mode
        when :review_method      then review_method_enabled?(project, field.method)
        when :quality_gate       then project.quality_gates_enabled?
        else raise ArgumentError, "Unsupported field kind: #{field.kind.inspect}"
        end
      end

      def write(project, key, value)
        field = lookup(key)
        case field.kind
        when :boolean_attribute then project.public_send("#{field.column}=", cast_bool(value))
        when :enum_attribute     then project.public_send("#{field.column}=", value.to_s)
        when :adoption_mode      then write_interop(project, "adoption_mode", value.to_s)
        when :review_method      then write_review_method(project, field.method, cast_bool(value))
        when :quality_gate       then write_quality_gate(project, cast_bool(value))
        else raise ArgumentError, "Unsupported field kind: #{field.kind.inspect}"
        end
      end

      # Reads every field into a {String} => value hash. Used for snapshots,
      # posture matching, and activity audit metadata.
      def snapshot(project)
        keys.to_h { |key| [key.to_s, read(project, key)] }
      end

      # Values considered "equivalent" for posture matching — normalizes
      # strings/booleans so +true+ vs +"true"+ and +"off"+ vs +false+ (for
      # auto-merge posture) don't create spurious mismatches.
      def equivalent?(left, right)
        normalize(left) == normalize(right)
      end

      private

      def normalize(value)
        return cast_bool(value) if [ true, false, "true", "false" ].any? { |v| value == v }

        value.to_s
      end

      def cast_bool(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end

      def review_method_enabled?(project, method_name)
        project.effective_review_settings.dig("methods", method_name, "enabled") == true
      end

      def write_interop(project, setting_key, value)
        settings = (project.interop_settings.is_a?(Hash) ? project.interop_settings.deep_stringify_keys : {})
        settings[setting_key] = value
        project.interop_settings = settings
      end

      def write_review_method(project, method_name, enabled)
        settings = (project.review_settings.is_a?(Hash) ? project.review_settings.deep_stringify_keys : {})
        settings["methods"] ||= {}
        settings["methods"][method_name] ||= {}
        settings["methods"][method_name]["enabled"] = enabled
        project.review_settings = settings
      end

      def write_quality_gate(project, enabled)
        settings = (project.quality_gate_settings.is_a?(Hash) ? project.quality_gate_settings.deep_stringify_keys : {})
        settings["enabled"] = enabled
        project.quality_gate_settings = settings
      end
    end
  end
end
