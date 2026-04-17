# frozen_string_literal: true

module Onboarding
  # Provisions default prompts and style guides for a new tenant account.
  # Called during the configure_defaults onboarding step.
  #
  # @example
  #   Onboarding::ProvisionDefaults.call(account: account)
  class ProvisionDefaults
    DEFAULT_PROMPTS = [
      {
        name: "Default Planning Prompt",
        slug: "default-planning",
        category: "planning",
        description: "Break down issues into implementation steps",
        template: "Analyze the following issue and create a detailed implementation plan:\n\n{{issue_description}}\n\nProvide step-by-step instructions with file paths and code changes needed."
      },
      {
        name: "Default Coding Prompt",
        slug: "default-coding",
        category: "coding",
        description: "Generate code changes based on a plan",
        template: "Implement the following changes according to the plan:\n\n{{plan}}\n\nFollow the project's coding conventions and style guide. Write clean, well-tested code."
      },
      {
        name: "Default Review Prompt",
        slug: "default-review",
        category: "review",
        description: "Review pull request changes for quality",
        template: "Review the following code changes:\n\n{{diff}}\n\nCheck for bugs, security issues, style violations, and suggest improvements."
      },
      {
        name: "Default Testing Prompt",
        slug: "default-testing",
        category: "testing",
        description: "Generate test cases for code changes",
        template: "Write comprehensive tests for the following code changes:\n\n{{changes}}\n\nCover edge cases, error scenarios, and integration tests."
      }
    ].freeze

    DEFAULT_STYLE_GUIDE = {
      name: "General Coding Standards",
      raw_content: <<~CONTENT
        # General Coding Standards

        ## Code Quality
        - Write clear, self-documenting code with meaningful names
        - Keep functions small and focused on a single responsibility
        - Prefer composition over inheritance
        - Handle errors explicitly, don't swallow exceptions

        ## Git Practices
        - Write descriptive commit messages using conventional commits
        - Keep commits atomic and focused
        - Reference issue numbers in commits

        ## Testing
        - Write tests for all new functionality
        - Test behavior, not implementation details
        - Use descriptive test names that explain the expected behavior
      CONTENT
    }.freeze

    def initialize(account:)
      @account = account
    end

    def self.call(...)
      new(...).provision
    end

    def provision
      ActiveRecord::Base.transaction do
        provision_prompts
        provision_style_guide
      end
    end

    private

    def provision_prompts
      DEFAULT_PROMPTS.each do |prompt_attrs|
        next if @account.prompts.exists?(slug: prompt_attrs[:slug])

        prompt = @account.prompts.create!(
          name: prompt_attrs[:name],
          slug: prompt_attrs[:slug],
          category: prompt_attrs[:category],
          description: prompt_attrs[:description]
        )

        prompt.create_version!(
          template: prompt_attrs[:template],
          change_notes: "Initial default prompt"
        )
      end
    end

    def provision_style_guide
      return if @account.style_guides.exists?(name: DEFAULT_STYLE_GUIDE[:name])

      @account.style_guides.create!(
        name: DEFAULT_STYLE_GUIDE[:name],
        raw_content: DEFAULT_STYLE_GUIDE[:raw_content]
      )
    end
  end
end
