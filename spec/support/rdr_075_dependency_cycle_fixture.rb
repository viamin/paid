# frozen_string_literal: true

module Rdr075DependencyCycleFixture
  Fixture = Data.define(:user, :project, :issues, :dependencies)

  ISSUE_NUMBERS = {
    closeout: 4334,
    design_acceptance: 4635,
    tool_validation: 4604
  }.freeze

  ISSUE_TITLES = {
    closeout: "RDR-075 C75: Validate and close out general maintenance runs",
    design_acceptance: "RDR-075: finalize and obtain explicit acceptance of maintenance HLD/LLD/EARS",
    tool_validation: "RDR-075: Collect the deferred live execution-environment validations for the M00 tool handoff"
  }.freeze

  # The live declaration is intentionally represented in the issue body while
  # the imported dependency rows omit provenance. This is the regression shape
  # used by the bounded repair path to locate a unique declaration safely.
  ISSUE_BODIES = {
    closeout: "## Dependencies\n\nDepends on #4635\n",
    design_acceptance: "## Dependencies\n\nDepends on #4604\n",
    tool_validation: "## Dependencies\n\nDepends on #4334\n"
  }.freeze

  EDGES = [
    [ :closeout, :design_acceptance ],
    [ :design_acceptance, :tool_validation ],
    [ :tool_validation, :closeout ]
  ].freeze

  def create_rdr_075_dependency_cycle_fixture
    user = create(:user)
    project = create(:project, account: user.account, created_by: user)
    issues = ISSUE_NUMBERS.to_h do |key, number|
      [ key, create(:issue, project:, github_number: number, title: ISSUE_TITLES.fetch(key),
        body: ISSUE_BODIES.fetch(key), github_state: "open", paid_state: "new") ]
    end
    dependencies = EDGES.map do |from, to|
      create_legacy_issue_dependency(issue: issues.fetch(from), depends_on_issue: issues.fetch(to))
    end

    Fixture.new(user:, project:, issues:, dependencies:)
  end
end

RSpec.configure do |config|
  config.include Rdr075DependencyCycleFixture
end
