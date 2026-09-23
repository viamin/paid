# frozen_string_literal: true

module Projects
  # Builds the grill-me bootstrap questionnaire used to capture a blank
  # project's initial setup decisions (issue #3954). The same text powers the
  # chat setup system prompt and the GitHub bootstrap issue body.
  #
  # @spec PROJECT-CREATION-009
  # @spec PROJECT-CREATION-010
  class BuildSetupPrompt
    def self.call(project:)
      new(project: project).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      <<~PROMPT.strip
        You are guiding the bootstrap of "#{project.name}" (#{project.full_name}), a brand-new repository created by Paid with no code, tooling, or conventions yet.

        Before this project can host meaningful agent runs, the initial tooling decisions must be captured. Interview me one topic at a time — ask focused questions, offer concrete options when they exist, and push back on vague or contradictory answers until you have enough to act on. This is a "grill me" interview: prefer pointed follow-ups over polite acceptance.

        Capture a decision for each of these areas:

        1. Language and framework — which language, which framework (if any), and which version.
        2. Dependencies — package manager, core libraries, and versioning strategy.
        3. Build and run — how the app is built, run locally, and structured on disk.
        4. CI — which provider, which workflows (test, lint, build), and required checks before merge.
        5. Testing — test framework, layout, and coverage expectations.
        6. Linting and formatting — tooling and config files.
        7. Repository conventions — branch naming, commit message style, PR process, and the project's default working agreement with Paid agents.

        When an area already has a recorded answer, summarize it back and confirm before moving on. Once every area has a decision, propose the concrete next step: file the bootstrap work as GitHub issues so agents can scaffold the repository (a README, dependency manifests, CI workflows, and lint config) and open their first pull requests.
      PROMPT
    end

    private

    attr_reader :project
  end
end
