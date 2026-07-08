# frozen_string_literal: true

module ConfigurationProfiles
  # Read-only reverse-engineering of a project's current operating posture.
  # Given a {::Project}, snapshots its {FieldSet} values and finds the nearest
  # {Profile}, reporting whether it is an exact match and exactly which fields
  # differ. This is what powers "what posture am I in?" answers in the chat
  # without mutating anything.
  class PostureDescriber
    Difference = Data.define(:field, :current, :target)

    Result = Data.define(:profile, :exact?, :differences, :matching_fields, :total_fields) do
      def match_kind
        exact? ? :exact : :nearest
      end

      def summary
        return "#{profile.name} (exact match)" if exact?

        noun = "field".pluralize(differences.length)
        "#{profile.name} (nearest, #{differences.length} #{noun} differ)"
      end
    end

    class << self
      # Convenience entry point matching the issue's +describe_current_posture+
      # naming.
      def describe_current_posture(project)
        describe(project)
      end

      def describe(project)
        snapshot = FieldSet.snapshot(project)
        profile, differences = nearest_profile(snapshot)
        total = FieldSet.keys.length
        Result.new(
          profile:,
          exact?: differences.empty?,
          differences:,
          matching_fields: total - differences.length,
          total_fields: total
        )
      end

      private

      def nearest_profile(snapshot)
        best = nil
        best_diff = nil
        Registry.all.each do |profile|
          diff = profile.diff_against(snapshot)
          next unless best.nil? || diff.length < best_diff.length

          best = profile
          best_diff = diff
        end
        [ best, best_diff.map { |change| Difference.new(field: change.field, current: change.from, target: change.to) } ]
      end
    end
  end
end
