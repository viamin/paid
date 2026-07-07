# frozen_string_literal: true

module Configuration
  module Profiles
    # Describes how to read the current resolved value of a profile target key
    # from a {Project} and how to write a new value back. Each descriptor also
    # declares its authorization +level+ (today only +:project+) so {Applier}
    # can authorize per level, and the +attribute+ name surfaced in activity
    # metadata.
    class Descriptor < Struct.new(:key, :attribute, :level, :read, :write, keyword_init: true)
      def level
        super || :project
      end
    end

    # Registry of the bounded set of profile target keys. Adding a new key here
    # is the only change needed to let profiles target a new setting — profiles
    # themselves only ever reference these string keys, never raw columns.
    module Settings
      module_function

      DESCRIPTORS = {
        "active" => Descriptor.new(
          key: "active", attribute: "active",
          read: ->(project) { project.active },
          write: ->(project, value) { project.active = value }
        ),
        "auto_pick_enabled" => Descriptor.new(
          key: "auto_pick_enabled", attribute: "auto_pick_enabled",
          read: ->(project) { project.auto_pick_enabled },
          write: ->(project, value) { project.auto_pick_enabled = value }
        ),
        "automation_on_label_enabled" => Descriptor.new(
          key: "automation_on_label_enabled", attribute: "automation_on_label_enabled",
          read: ->(project) { project.automation_on_label_enabled },
          write: ->(project, value) { project.automation_on_label_enabled = value }
        ),
        "owner_reviewer_login" => Descriptor.new(
          key: "owner_reviewer_login", attribute: "owner_reviewer_login",
          read: ->(project) { project.owner_reviewer_login },
          write: ->(project, value) { project.owner_reviewer_login = value }
        ),
        "adoption_mode" => Descriptor.new(
          key: "adoption_mode", attribute: "interop_settings",
          read: ->(project) { project.adoption_mode },
          write: ->(project, value) { merge_jsonb(project, :interop_settings, "adoption_mode", value) }
        ),
        "review_enabled" => Descriptor.new(
          key: "review_enabled", attribute: "review_settings",
          read: ->(project) { project.effective_review_settings["enabled"] },
          write: ->(project, value) { merge_jsonb(project, :review_settings, "enabled", value) }
        ),
        "quality_gate_enabled" => Descriptor.new(
          key: "quality_gate_enabled", attribute: "quality_gate_settings",
          read: ->(project) { project.effective_quality_gate_settings["enabled"] },
          write: ->(project, value) { merge_jsonb(project, :quality_gate_settings, "enabled", value) }
        )
      }.freeze

      def fetch(key)
        DESCRIPTORS.fetch(key.to_s)
      rescue KeyError
        raise ArgumentError, "Unsupported configuration profile setting: #{key.inspect}"
      end

      def read(project, key)
        fetch(key).read.call(project)
      end

      def write(project, key, value)
        fetch(key).write.call(project, value)
      end

      # Deep-merges a single key into a JSONB-backed column, preserving the
      # rest of the stored hash. Used for nested settings
      # (+interop_settings+, +review_settings+, +quality_gate_settings+).
      def merge_jsonb(project, column, key, value)
        current = project.public_send(column)
        current = current.is_a?(Hash) ? current.deep_stringify_keys : {}
        project.public_send(:"#{column}=", current.merge(key => value))
      end
    end
  end
end
