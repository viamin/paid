# frozen_string_literal: true

module PromptAssembly
  # Assembles the goal-wrapper section(s) for an agent run through
  # PromptAssembly::Build, producing prompt text plus section-level
  # provenance and a digest.
  #
  # The migrated goal wrappers — create-issue, review, enhance-issue, and
  # interactive verification — are contributed as explicit Sections with trust
  # metadata so they cannot be silently dropped by customization and so their
  # inclusion is recorded in run/configuration provenance. Safety-critical
  # goal sections are marked +required+, which means a Profile may not
  # suppress them.
  #
  # The goal wrapper templates embed the base prompt (via +{{base_prompt}}+),
  # so for create-issue/enhance-issue/review goals the fully-rendered wrapper
  # is contributed as a single +goal.*+ section whose text already contains the
  # base task. For create-pr goals the base prompt is a +task.base+ section and
  # interactive verification is appended as a separate +verification.interactive+
  # section. Goals without a migrated wrapper contribute only the base section.
  #
  # @spec PROMPT-ASSEMBLY-005, PROMPT-ASSEMBLY-006
  class GoalAssembly
    SECTION_KEYS = {
      "create_issue" => :"goal.create_issue",
      "enhance_issue" => :"goal.enhance_issue",
      "review" => :"goal.review"
    }.freeze

    VERIFICATION_KEY = :"verification.interactive"
    BASE_KEY = :"task.base"

    def self.call(agent_run:, base_prompt:, goal_text: nil, verification_text: nil)
      new(agent_run: agent_run, base_prompt: base_prompt).call(
        goal_text: goal_text, verification_text: verification_text
      )
    end

    attr_reader :agent_run, :base_prompt

    def initialize(agent_run:, base_prompt:)
      @agent_run = agent_run
      @base_prompt = base_prompt.to_s
    end

    # goal_text: the fully-rendered goal-wrapper prompt (base embedded) for
    #   create_issue/enhance_issue/review goals, or nil.
    # verification_text: the interactive verification section content for
    #   create_pr goals, or nil.
    def call(goal_text: nil, verification_text: nil)
      PromptAssembly::Build.call(sections: build_sections(goal_text:, verification_text:))
    end

    def goal_section_key
      SECTION_KEYS[agent_run.goal]
    end

    private

    def build_sections(goal_text:, verification_text:)
      if goal_text.present?
        [ safety_section(goal_section_key || BASE_KEY, goal_text, "goal wrapper") ]
      else
        sections = [ base_section ]
        if verification_text.present?
          sections << safety_section(VERIFICATION_KEY, verification_text, "interactive verification")
        end
        sections
      end
    end

    def base_section
      Section.new(
        key: BASE_KEY,
        source: :effective_prompt,
        content: base_prompt,
        trust_level: :trusted,
        inclusion_reason: "base prompt from effective_prompt"
      )
    end

    def safety_section(key, content, inclusion_reason)
      Section.new(
        key: key,
        source: :activity,
        content: content,
        trust_level: :trusted,
        required: true,
        inclusion_reason: inclusion_reason
      )
    end
  end
end
