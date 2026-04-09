# frozen_string_literal: true

require "rails_helper"

# Loads db/seeds/prompts.rb and verifies that every seeded prompt:
#   1. Creates a Prompt + current PromptVersion row
#   2. Renders without leaving any unresolved {{variable}} placeholders
#      when given the variables declared in its `variables` metadata
#
# This is the regression net for the "all prompts in the table" migration —
# if a caller adds a new {{var}} to its template without declaring it in the
# seed metadata, this spec will fail.
EXPECTED_SEEDED_PROMPT_SLUGS = %w[
  coding.issue_implementation
  coding.pr_review_rebase
  diagnostics.agent_run_failure
  planning.decompose_feature
  planning.model_selection
  evolution.mutate_prompt
  style.extract_guide
  style.compress_guide
  generation.issue_title
  generation.pr_description
  knowledge.draft_decision
].freeze

RSpec.describe Prompt, type: :model do
  before do
    load Rails.root.join("db/seeds/prompts.rb").to_s
  end

  EXPECTED_SEEDED_PROMPT_SLUGS.each do |slug|
    describe "prompt #{slug}" do
      let(:prompt) { described_class.global.find_by(slug: slug) }
      let(:version) { prompt&.current_version }

      it "exists with an active current version" do
        expect(prompt).to be_present
        expect(prompt.active).to be true
        expect(version).to be_present
      end

      it "renders without leaving unresolved {{variables}}" do
        vars = Array(version.variables).each_with_object({}) do |v, h|
          name = v.is_a?(Hash) ? (v["name"] || v[:name]) : v.to_s
          h[name.to_sym] = "X"
        end

        rendered = version.render(vars)
        unresolved = rendered.scan(/\{\{[^{}]+\}\}/)
        expect(unresolved).to be_empty,
          "expected no unresolved placeholders in #{slug}, got: #{unresolved.inspect}"
      end
    end
  end

  it "covers every expected slug exactly" do
    actual = described_class.global.where(slug: EXPECTED_SEEDED_PROMPT_SLUGS).pluck(:slug).sort
    expect(actual).to eq(EXPECTED_SEEDED_PROMPT_SLUGS.sort)
  end
end
