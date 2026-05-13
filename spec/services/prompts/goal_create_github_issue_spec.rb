# frozen_string_literal: true

require "spec_helper"
require_relative "../../../app/services/prompts/goal_create_github_issue"

RSpec.describe Prompts::GoalCreateGithubIssue, :no_db do
  it "declares the expected prompt slug and variables" do
    expect(described_class::PROMPT_SLUG).to eq("goal.create_github_issue")
    expect(described_class::VARIABLES).to eq(
      [
        {
          "name" => "base_prompt",
          "required" => true,
          "description" => "The base prompt this augmentation extends"
        },
        {
          "name" => "repo",
          "required" => true,
          "description" => "Repository full_name (owner/repo)"
        },
        {
          "name" => "decomposition_instructions",
          "required" => true,
          "description" => "Feature decomposition instructions (injected when scope analysis triggers decomposition)"
        }
      ]
    )
  end

  it "keeps the non-interactive drafting instructions in the shared template" do
    expect(described_class::TEMPLATE).to include(
      "Treat the request and repository context already provided above as the full source"
    )
    expect(described_class::TEMPLATE).to include(
      "Do NOT reply by asking the user to provide the issue type, title, description,"
    )
    expect(described_class::TEMPLATE).to include("When no labels are\nclearly requested, omit them.")
  end
end
