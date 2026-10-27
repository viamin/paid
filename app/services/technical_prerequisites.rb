# frozen_string_literal: true

# Namespace for the technical-prerequisite recovery services. A validation
# records its reviewed recipe under +RECIPE_KEY+ in the run's external
# metadata and its evidence under +EVIDENCE_KEY+ in the run's verification
# result, so the operator and the closeout assessment read the same record.
module TechnicalPrerequisites
  # @spec PARTIAL-CLOSEOUT-032
  RECIPE_KEY = "technical_prerequisite_validation"
  # @spec PARTIAL-CLOSEOUT-032
  EVIDENCE_KEY = "technical_prerequisite_validation"
end
