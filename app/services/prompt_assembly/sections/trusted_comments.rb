# frozen_string_literal: true

# Trusted conversation comments from issue collaborators. Untrusted comments
# (from non-allowlisted GitHub users) are excluded so prompt-injection
# content cannot reach the agent through the comment thread.
class PromptAssembly::Sections::TrustedComments
  include PromptAssembly::Sections::Base

  private

  def build_section
    Prompts::BuildForIssue.conversation_section_for(
      project: project,
      issue: issue,
      github_client: github_client,
      issue_comments: issue_comments
    )
  end

  def inclusion_reason
    "trusted collaborator comments"
  end

  def skip_reason
    return "no_github_client" unless github_client
    return "no_trusted_comments" if trusted_comments.empty?

    nil
  end

  def trusted_comments
    @trusted_comments ||= Prompts::BuildForIssue.fetch_trusted_comments(
      github_client: github_client,
      repo: project.full_name,
      number: issue.github_number,
      project: project,
      comments: issue_comments
    )
  end
end
