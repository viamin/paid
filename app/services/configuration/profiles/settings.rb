# frozen_string_literal: true

module Configuration
  module Profiles
    # Describes how to read the current resolved value of a profile target key
    # from a {Context} and how to write a new value back. Each descriptor also
    # declares its authorization +level+ so {Planner}/{Applier} can report
    # mixed-scope changes and skipped levels consistently.
    class Descriptor < Struct.new(:key, :attribute, :level, :label, :record, :read, :write, :coerce, keyword_init: true)
      def level
        super || :project
      end

      def record
        super || ->(context) { context.project }
      end

      def coerce
        super || ->(value) { value }
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

      DESCRIPTORS = {
        "active" => Descriptor.new(
          key: "active", attribute: "active", label: "Project active",
          read: ->(project) { project.active },
          write: ->(project, value) { project.active = value },
          coerce: BOOLEAN
        ),
        "auto_pick_enabled" => Descriptor.new(
          key: "auto_pick_enabled", attribute: "auto_pick_enabled", label: "Auto-pick issues",
          read: ->(project) { project.auto_pick_enabled },
          write: ->(project, value) { project.auto_pick_enabled = value },
          coerce: BOOLEAN
        ),
        "automation_on_label_enabled" => Descriptor.new(
          key: "automation_on_label_enabled", attribute: "automation_on_label_enabled",
          label: "Automation on label",
          read: ->(project) { project.automation_on_label_enabled },
          write: ->(project, value) { project.automation_on_label_enabled = value },
          coerce: BOOLEAN
        ),
        "owner_reviewer_login" => Descriptor.new(
          key: "owner_reviewer_login", attribute: "owner_reviewer_login", label: "Owner reviewer login",
          read: ->(project) { project.owner_reviewer_login },
          write: ->(project, value) { project.owner_reviewer_login = value },
          coerce: GITHUB_LOGIN
        ),
        "adoption_mode" => Descriptor.new(
          key: "adoption_mode", attribute: "interop_settings", label: "Adoption mode",
          read: ->(project) { project.adoption_mode },
          write: ->(project, value) { merge_jsonb(project, :interop_settings, "adoption_mode", value) }
        ),
        "review_enabled" => Descriptor.new(
          key: "review_enabled", attribute: "review_settings", label: "Review enabled",
          read: ->(project) { project.effective_review_settings["enabled"] },
          write: ->(project, value) { merge_jsonb(project, :review_settings, "enabled", value) },
          coerce: BOOLEAN
        ),
        "quality_gate_enabled" => Descriptor.new(
          key: "quality_gate_enabled", attribute: "quality_gate_settings", label: "Quality gate enabled",
          read: ->(project) { project.effective_quality_gate_settings["enabled"] },
          write: ->(project, value) { merge_jsonb(project, :quality_gate_settings, "enabled", value) },
          coerce: BOOLEAN
        ),
        "run_concurrency_mode" => Descriptor.new(
          key: "run_concurrency_mode", attribute: "run_concurrency_mode", level: :user,
          label: "Run concurrency mode",
          record: ->(context) { context.user_setting },
          read: ->(user_setting) { user_setting&.run_concurrency_mode },
          write: ->(user_setting, value) { user_setting.run_concurrency_mode = value.to_s }
        ),
        "agent_auto_continue" => Descriptor.new(
          key: "agent_auto_continue", attribute: "agent_settings", level: :tenant,
          label: "Agent auto-continue",
          record: ->(context) { context.tenant_setting },
          read: ->(tenant_setting) { tenant_setting&.effective_agent_settings&.dig("auto_continue") },
          write: ->(tenant_setting, value) { merge_jsonb(tenant_setting, :agent_settings, "auto_continue", value) },
          coerce: BOOLEAN
        )
      }.freeze

      def all
        DESCRIPTORS.values
      end

      def fetch(key)
        DESCRIPTORS.fetch(key.to_s)
      rescue KeyError
        raise ArgumentError, "Unsupported configuration profile setting: #{key.inspect}"
      end

      def read(context, key)
        descriptor = fetch(key)
        descriptor.read.call(descriptor.record.call(context))
      end

      def write(context, key, value)
        descriptor = fetch(key)
        descriptor.write.call(descriptor.record.call(context), descriptor.coerce.call(value))
      end

      def normalize(key, value)
        descriptor = fetch(key)
        descriptor.coerce.call(value)
      end

      # Deep-merges a single key into a JSONB-backed column, preserving the
      # rest of the stored hash. Used for nested settings
      # (+interop_settings+, +review_settings+, +quality_gate_settings+,
      # +agent_settings+).
      def merge_jsonb(record, column, key, value)
        current = record.public_send(column)
        current = current.is_a?(Hash) ? current.deep_stringify_keys : {}
        record.public_send(:"#{column}=", current.merge(key => value))
      end
    end
  end
end
