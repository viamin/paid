# frozen_string_literal: true

module Configuration
  module Profiles
    # Describes how to read the current resolved value of a profile target key
    # from a {Project} and how to write a new value back. Each descriptor also
    # declares its authorization +level+ (today only +:project+) so {Applier}
    # can authorize per level, and the +attribute+ name surfaced in activity
    # metadata.
    class Descriptor < Struct.new(
      :key, :attribute, :level, :label, :read, :write, :coerce, :kind, :column, :options, :method_name, :target,
      keyword_init: true
    )
      def level
        super || :project
      end

      def coerce
        super || ->(value) { value }
      end

      def target?
        target != false
      end
    end

    # Registry of the bounded set of profile target keys. Adding a new key here
    # is the only change needed to let profiles target a new setting — profiles
    # themselves only ever reference these string keys, never raw columns.
    module Settings
      module_function

      BOOLEAN_TRUE_VALUES = [ true, 1, "1", "true" ].freeze
      BOOLEAN_FALSE_VALUES = [ false, 0, "0", "false" ].freeze
      BOOLEAN = lambda do |value|
        return value if value == true || value == false

        normalized = value.is_a?(String) ? value.strip.downcase : value
        return true if BOOLEAN_TRUE_VALUES.include?(normalized)
        return false if BOOLEAN_FALSE_VALUES.include?(normalized)

        raise ArgumentError,
              "Invalid boolean override #{value.inspect}; expected true, false, \"true\", \"false\", 1, or 0"
      end
      GITHUB_LOGIN = lambda do |value|
        unless value.is_a?(String)
          raise ArgumentError, "Invalid GitHub login override #{value.inspect}; expected a string"
        end

        value.strip
      end
      MODE_RELEVANT_COLUMN_PATTERNS = [
        /\Aauto_/,
        /_enabled\z/,
        "automation_on_label_enabled",
        "pr_aggregation_enabled",
        "allow_bot_authored_pr_auto_merge",
        "merge_method"
      ].freeze
      EXCLUDED_ATTRIBUTE_COLUMNS = {
        "auto_pick_skip_labels" => "label override, not an automation toggle",
        "git_push_pat_fallback_enabled" => "credential fallback, not an automation toggle"
      }.freeze

      def enum(values)
        allowed = values.map(&:to_s).freeze
        lambda do |value|
          normalized = value.to_s
          return normalized if allowed.include?(normalized)

          raise ArgumentError,
                "Invalid override #{value.inspect}; expected one of #{allowed.join(', ')}"
        end
      end

      DESCRIPTORS = {
        "active" => Descriptor.new(
          key: "active", attribute: "active", label: "Project active", kind: :boolean_attribute, column: "active",
          read: ->(project) { project.active },
          write: ->(project, value) { project.active = value },
          coerce: BOOLEAN,
          target: false
        ),
        "auto_pick_enabled" => Descriptor.new(
          key: "auto_pick_enabled", attribute: "auto_pick_enabled", label: "Auto-pick issues",
          kind: :boolean_attribute, column: "auto_pick_enabled",
          read: ->(project) { project.auto_pick_enabled },
          write: ->(project, value) { project.auto_pick_enabled = value },
          coerce: BOOLEAN
        ),
        "auto_scan_prs" => Descriptor.new(
          key: "auto_scan_prs", attribute: "auto_scan_prs", label: "Auto-continue (scan PRs)",
          kind: :boolean_attribute, column: "auto_scan_prs",
          read: ->(project) { project.auto_scan_prs },
          write: ->(project, value) { project.auto_scan_prs = value },
          coerce: BOOLEAN
        ),
        "automation_on_label_enabled" => Descriptor.new(
          key: "automation_on_label_enabled", attribute: "automation_on_label_enabled",
          label: "Run automation on label", kind: :boolean_attribute, column: "automation_on_label_enabled",
          read: ->(project) { project.automation_on_label_enabled },
          write: ->(project, value) { project.automation_on_label_enabled = value },
          coerce: BOOLEAN
        ),
        "auto_merge_mode" => Descriptor.new(
          key: "auto_merge_mode", attribute: "auto_merge_mode", label: "Auto-merge mode",
          kind: :enum_attribute, column: "auto_merge_mode", options: %w[off dependabot_only all],
          read: ->(project) { project.auto_merge_mode },
          write: ->(project, value) { project.auto_merge_mode = value },
          coerce: enum(%w[off dependabot_only all])
        ),
        "auto_fix_merge_conflicts" => Descriptor.new(
          key: "auto_fix_merge_conflicts", attribute: "auto_fix_merge_conflicts", label: "Auto-fix merge conflicts",
          kind: :boolean_attribute, column: "auto_fix_merge_conflicts",
          read: ->(project) { project.auto_fix_merge_conflicts },
          write: ->(project, value) { project.auto_fix_merge_conflicts = value },
          coerce: BOOLEAN
        ),
        "merge_method" => Descriptor.new(
          key: "merge_method", attribute: "merge_method", label: "Merge method",
          kind: :enum_attribute, column: "merge_method", options: Project::MERGE_METHODS,
          read: ->(project) { project.merge_method },
          write: ->(project, value) { project.merge_method = value },
          coerce: enum(Project::MERGE_METHODS)
        ),
        "auto_release_granularity" => Descriptor.new(
          key: "auto_release_granularity", attribute: "auto_release_granularity", label: "Auto-release granularity",
          kind: :enum_attribute, column: "auto_release_granularity", options: Project::AUTO_RELEASE_GRANULARITIES,
          read: ->(project) { project.auto_release_granularity },
          write: ->(project, value) { project.auto_release_granularity = value },
          coerce: enum(Project::AUTO_RELEASE_GRANULARITIES)
        ),
        "auto_enhance_enabled" => Descriptor.new(
          key: "auto_enhance_enabled", attribute: "auto_enhance_enabled", label: "Auto-enhance before PR",
          kind: :boolean_attribute, column: "auto_enhance_enabled",
          read: ->(project) { project.auto_enhance_enabled },
          write: ->(project, value) { project.auto_enhance_enabled = value },
          coerce: BOOLEAN
        ),
        "auto_add_labels_enabled" => Descriptor.new(
          key: "auto_add_labels_enabled", attribute: "auto_add_labels_enabled", label: "Auto-add labels",
          kind: :boolean_attribute, column: "auto_add_labels_enabled",
          read: ->(project) { project.auto_add_labels_enabled },
          write: ->(project, value) { project.auto_add_labels_enabled = value },
          coerce: BOOLEAN
        ),
        "pr_aggregation_enabled" => Descriptor.new(
          key: "pr_aggregation_enabled", attribute: "pr_aggregation_enabled", label: "Aggregate decomposed PRs",
          kind: :boolean_attribute, column: "pr_aggregation_enabled",
          read: ->(project) { project.pr_aggregation_enabled },
          write: ->(project, value) { project.pr_aggregation_enabled = value },
          coerce: BOOLEAN
        ),
        "auto_scan_security" => Descriptor.new(
          key: "auto_scan_security", attribute: "auto_scan_security", label: "Auto-scan security alerts",
          kind: :boolean_attribute, column: "auto_scan_security",
          read: ->(project) { project.auto_scan_security },
          write: ->(project, value) { project.auto_scan_security = value },
          coerce: BOOLEAN
        ),
        "knowledge_evolution_enabled" => Descriptor.new(
          key: "knowledge_evolution_enabled", attribute: "knowledge_evolution_enabled", label: "Knowledge evolution",
          kind: :boolean_attribute, column: "knowledge_evolution_enabled",
          read: ->(project) { project.knowledge_evolution_enabled },
          write: ->(project, value) { project.knowledge_evolution_enabled = value },
          coerce: BOOLEAN
        ),
        "allow_bot_authored_pr_auto_merge" => Descriptor.new(
          key: "allow_bot_authored_pr_auto_merge", attribute: "allow_bot_authored_pr_auto_merge",
          label: "Allow bot-authored PR auto-merge", kind: :boolean_attribute, column: "allow_bot_authored_pr_auto_merge",
          read: ->(project) { project.allow_bot_authored_pr_auto_merge },
          write: ->(project, value) { project.allow_bot_authored_pr_auto_merge = value },
          coerce: BOOLEAN
        ),
        "owner_reviewer_login" => Descriptor.new(
          key: "owner_reviewer_login", attribute: "owner_reviewer_login", label: "Owner reviewer login",
          kind: :string_attribute, column: "owner_reviewer_login",
          read: ->(project) { project.owner_reviewer_login },
          write: ->(project, value) { project.owner_reviewer_login = value },
          coerce: GITHUB_LOGIN,
          target: false
        ),
        "adoption_mode" => Descriptor.new(
          key: "adoption_mode", attribute: "interop_settings", label: "Adoption mode",
          kind: :adoption_mode, options: Project::ADOPTION_MODES,
          read: ->(project) { project.adoption_mode },
          write: ->(project, value) { merge_jsonb(project, :interop_settings, "adoption_mode", value) },
          coerce: enum(Project::ADOPTION_MODES)
        ),
        "review_enabled" => Descriptor.new(
          key: "review_enabled", attribute: "review_settings", label: "Review enabled",
          kind: :review_enabled,
          read: ->(project) { project.effective_review_settings["enabled"] },
          write: ->(project, value) { merge_jsonb(project, :review_settings, "enabled", value) },
          coerce: BOOLEAN,
          target: false
        ),
        "review_paid_agent" => Descriptor.new(
          key: "review_paid_agent", attribute: "review_settings", label: "Paid-agent review",
          kind: :review_method, method_name: "paid_agent",
          read: ->(project) { review_method_enabled?(project, "paid_agent") },
          write: ->(project, value) { write_review_method(project, "paid_agent", value) },
          coerce: BOOLEAN
        ),
        "review_copilot" => Descriptor.new(
          key: "review_copilot", attribute: "review_settings", label: "Copilot review",
          kind: :review_method, method_name: "copilot",
          read: ->(project) { review_method_enabled?(project, "copilot") },
          write: ->(project, value) { write_review_method(project, "copilot", value) },
          coerce: BOOLEAN
        ),
        "quality_gate_enabled" => Descriptor.new(
          key: "quality_gate_enabled", attribute: "quality_gate_settings", label: "Quality gate enabled",
          kind: :quality_gate,
          read: ->(project) { project.quality_gates_enabled? },
          write: ->(project, value) { write_quality_gate(project, value) },
          coerce: BOOLEAN
        )
      }.freeze

      def all
        DESCRIPTORS.values
      end

      def target_descriptors
        all.select(&:target?)
      end

      def profile_target_keys
        target_descriptors.map(&:key)
      end

      def fetch(key)
        DESCRIPTORS.fetch(key.to_s)
      rescue KeyError
        raise ArgumentError, "Unsupported configuration profile setting: #{key.inspect}"
      end

      def read(project, key)
        fetch(key).read.call(project)
      end

      def write(project, key, value)
        descriptor = fetch(key)
        descriptor.write.call(project, descriptor.coerce.call(value))
      end

      def normalize(key, value)
        descriptor = fetch(key)
        descriptor.coerce.call(value)
      end

      def attribute_columns
        target_descriptors.filter_map(&:column)
      end

      def excluded_attribute_columns
        EXCLUDED_ATTRIBUTE_COLUMNS.keys.freeze
      end

      def snapshot(project)
        profile_target_keys.to_h { |key| [ key, read(project, key) ] }
      end

      def equivalent?(left, right)
        normalize_equivalent_value(left) == normalize_equivalent_value(right)
      end

      # Deep-merges a single key into a JSONB-backed column, preserving the
      # rest of the stored hash. Used for nested settings
      # (+interop_settings+, +review_settings+, +quality_gate_settings+).
      def merge_jsonb(project, column, key, value)
        current = project.public_send(column)
        current = current.is_a?(Hash) ? current.deep_stringify_keys : {}
        project.public_send(:"#{column}=", current.merge(key => value))
      end

      def normalize_equivalent_value(value)
        return BOOLEAN.call(value) if [ true, false, "true", "false" ].include?(value)

        value.to_s
      rescue ArgumentError
        value
      end

      def review_method_enabled?(project, method_name)
        project.effective_review_settings.dig("methods", method_name, "enabled") == true
      end

      def write_review_method(project, method_name, enabled)
        settings = project.review_settings.is_a?(Hash) ? project.review_settings.deep_stringify_keys : {}
        settings["methods"] ||= {}
        settings["methods"][method_name] ||= {}
        settings["methods"][method_name]["enabled"] = enabled
        settings["enabled"] = any_review_method_enabled?(settings)
        project.review_settings = settings
      end

      def write_quality_gate(project, enabled)
        settings = project.quality_gate_settings.is_a?(Hash) ? project.quality_gate_settings.deep_stringify_keys : {}
        settings["enabled"] = enabled
        project.quality_gate_settings = settings
      end

      def any_review_method_enabled?(settings)
        settings.fetch("methods", {}).any? do |_method_name, method_settings|
          method_settings.is_a?(Hash) && method_settings["enabled"] == true
        end
      end
    end
  end
end
