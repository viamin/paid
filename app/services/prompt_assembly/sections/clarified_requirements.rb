# frozen_string_literal: true

# Clarified requirements extracted from the issue's clarifying-question flow.
# Only trusted collaborator answers are surfaced. When LID is enabled the
# heading changes to "# Elicited Intent".
class PromptAssembly::Sections::ClarifiedRequirements
  include PromptAssembly::Sections::Base

  private

  def build_section
    return "" unless github_client

    qa_pairs = ClarifyingQuestions::ExtractAnswerPairs.call(
      project: project,
      issue_comments: issue_comments,
      issue: issue
    ).qa_pairs
    return "" if qa_pairs.empty?

    lines = qa_pairs.each_with_index.flat_map do |qa, index|
      [
        "#{index + 1}. Question: #{qa[:question]}",
        "   Answer: #{qa[:answer]}"
      ]
    end

    [ heading, guidance, lines.join("\n") ]
      .join("\n\n")
      .delete("\u0000")
      .strip
  rescue GithubClient::Error
    ""
  end

  def inclusion_reason
    "confirmed human intent from the clarifying-question flow"
  end

  def skip_reason
    return "no_github_client" unless github_client

    "no_clarified_requirements"
  end

  def heading
    lid_enabled? ? "# Elicited Intent" : "# Clarified Requirements"
  end

  def guidance
    guidance_lines = [
      "These answers came from the issue's clarifying-question flow.",
      "Treat them as confirmed human intent while implementing the change."
    ]

    if lid_enabled?
      guidance_lines << "Carry them into any LID artifact updates you make while implementing the change."
      guidance_lines << "Draft or update the relevant LLD and EARS artifacts from these answers before or alongside code changes."
    end

    guidance_lines.join(" ")
  end

  # @spec ISSUE-ENHANCEMENT-004
  def lid_enabled?
    project.respond_to?(:lid_mode) && project.lid_mode.present?
  end
end
