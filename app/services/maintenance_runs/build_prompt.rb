# frozen_string_literal: true

module MaintenanceRuns
  # Builds the investigation prompt for a manual maintenance run from the
  # objective, scope, and guidance snapshotted at start. The prompt is the
  # M01 carrier for the RDR-075 investigation contract: resolve named targets
  # before claiming coverage, keep the scan report-only, and treat a fully
  # covered investigation with no findings as a success.
  class BuildPrompt
    def self.call(objective:, guidance:, scope:, type: nil, type_value: nil)
      new(objective:, guidance:, scope:, type:, type_value:).call
    end

    def initialize(objective:, guidance:, scope:, type: nil, type_value: nil)
      @objective = objective.presence
      @guidance = guidance.to_s.strip
      @scope = scope.to_s.strip.presence
      @type = type
      @type_value = type_value.to_s.presence
      raise ArgumentError, "an objective, optimization type, or nonblank guidance is required" if @objective.blank? && @guidance.blank? && @type_value.blank?
    end

    def call
      <<~PROMPT.chomp
        You are running a report-only maintenance investigation. You investigate the repository and produce a report. Do not modify source files; do not commit, push, or open a pull request. A completed investigation with no findings is a successful outcome — report it plainly.

        ## Objective
        #{objective_section}

        ## Scope
        #{scope_section}

        ## Guidance from the requester
        #{guidance.presence || "(none provided)"}

        ## Investigation contract
        - Resolve each named target before claiming coverage of it. If a named target is ambiguous or cannot be found, produce an actionable clarification outcome: state exactly which target is ambiguous or missing, what you looked for, and what clarification you need. Do not silently scan the whole repository instead.
        - The requested scope bounds your recommendations, not your access to supporting evidence. You may inspect callers, tests, framework entry points, and design documents anywhere in the repository to validate a claim.
        - Explain any recommendation that requires changes beyond the requested scope; expanding the repair scope requires explicit authorization from the requester.
        - Record the resolved scope you actually investigated and any exclusions in the report.
        - For each finding, report its category, the affected locations or symbols, the claim, supporting evidence, known counterevidence, and a proposed action. Similarity alone does not establish that code should be shared; absence of static references does not establish that code can be deleted.
        - If evidence is missing or an analysis could not be completed, say so explicitly as an unresolved candidate or coverage limitation. Never present an incomplete scan as a clean result.
      PROMPT
    end

    private

    attr_reader :objective, :guidance, :scope, :type, :type_value

    def objective_section
      recipe = Recipes.fetch(objective) if objective
      return recipe.objective_instructions if recipe

      return "#{type.name}: #{type.investigation_description}\nDefault metric hints: #{type.metric_hints.join(", ")}" if type

      return custom_type_instructions if type_value

      guidance
    end

    def custom_type_instructions
      direction = if guidance.present?
        "use the guidance below to determine what to investigate"
      else
        "infer the investigation goal from this value and record that interpretation in the report"
      end
      "Custom optimization objective selected: #{type_value}. Treat this as a requester-defined objective; #{direction}."
    end

    def scope_section
      return "Named targets (resolve before claiming coverage): #{scope}" if scope.present?

      "No scope was supplied: this is an explicit broad-scope investigation of the entire repository. Record that broad scope in the report."
    end
  end
end
