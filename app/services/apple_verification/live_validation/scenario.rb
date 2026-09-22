# frozen_string_literal: true

module AppleVerification
  module LiveValidation
    # One acceptance-validation scenario from issue #3978. The id is stable so
    # evidence rows can be matched across runs; +criterion+ names the
    # acceptance criterion ("AC1".."AC8") the scenario satisfies.
    # @spec APPLE-LIVE-001
    Scenario = Data.define(:id, :criterion, :group, :description, :expectation)
  end
end
