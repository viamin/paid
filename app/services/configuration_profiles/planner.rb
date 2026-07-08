# frozen_string_literal: true

module ConfigurationProfiles
  # Builds a {Plan} describing the {Change} set needed to move a {::Project}
  # from its current settings to a target posture. Targets can be a {Profile}
  # or an arbitrary field => value hash, which keeps the planner reusable for
  # future batch operations (quality-gate bundles, cost-budget presets).
  module Planner
    module_function

    # Accepts either a {Profile} or a values hash. When a hash is given,
    # +label+ and +source+ are required so every produced plan is auditable.
    def call(project, target, label: nil, source: :custom)
      if target.is_a?(Profile)
        for_profile(project, target)
      else
        for_values(project, target, label: label || "Apply custom settings", source:)
      end
    end

    def for_profile(project, profile)
      changes = profile.diff_against(FieldSet.snapshot(project))
      Plan.new(
        label: "Apply #{profile.name} posture",
        source: :configuration_profile,
        reference: profile.key,
        changes:
      )
    end

    def for_values(project, values, label:, source:)
      normalized = values.deep_stringify_keys
      snapshot = FieldSet.snapshot(project)
      changes = FieldSet.keys.filter_map do |key|
        next unless normalized.key?(key.to_s)

        current = snapshot[key.to_s]
        desired = normalized[key.to_s]
        next if FieldSet.equivalent?(current, desired)

        Change.new(field: key, from: current, to: desired)
      end
      Plan.new(label:, source:, changes:)
    end
  end
end
