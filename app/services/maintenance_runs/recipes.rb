# frozen_string_literal: true

module MaintenanceRuns
  # Catalog of maintenance recipe objectives (RDR-075). A recipe supplies a
  # reusable objective; a manual run may use a recipe or supply a nonblank
  # original question — a catalog entry is not required to investigate a
  # user-directed maintenance question. Tool-assisted evidence collectors and
  # their version pins belong to #4330, not this registry.
  # @spec MAINT-011
  module Recipes
    Recipe = Data.define(:key, :version, :name, :objective_instructions)

    UNNECESSARY_CODE = Recipe.new(
      key: "unnecessary_code",
      version: "1",
      name: "Unnecessary code",
      objective_instructions: <<~INSTRUCTIONS.chomp
        Investigate unnecessary code: unused code and dependencies, duplication,
        complexity, unnecessary abstractions, and obsolete behavior. Identify
        candidates with evidence, then verify each against repository intent —
        framework callbacks, reflection, external APIs, intentional
        independence, and compatibility obligations must be considered before
        claiming code is removable.
      INSTRUCTIONS
    ).freeze

    ALL = {
      UNNECESSARY_CODE.key => UNNECESSARY_CODE
    }.freeze

    class << self
      def fetch(key)
        ALL.fetch(key)
      end

      def keys
        ALL.keys
      end

      def exists?(key)
        ALL.key?(key)
      end
    end
  end
end
