# frozen_string_literal: true

# Trusted conversation comments from issue collaborators. Untrusted comments
# (from non-allowlisted GitHub users) are excluded so prompt-injection
# content cannot reach the agent through the comment thread.
class PromptAssembly::Sections::TrustedComments
  include PromptAssembly::Sections::Base

  private

  def build_section
    return "" unless github_client
    return "" if max_comments <= 0

    Prompts::BuildForIssue.format_conversation_section(
      trusted_comments,
      max_comment_length: max_comment_length
    )
  end

  def inclusion_reason
    "trusted collaborator comments"
  end

  def skip_reason
    return "no_github_client" unless github_client
    return "comments_disabled_by_settings" if max_comments <= 0
    return "no_trusted_comments" if trusted_comments.empty?

    nil
  end

  def section_metadata
    return unless github_client

    {
      comment_count: trusted_comments.size,
      untrusted_excluded: untrusted_comment_count
    }
  end

  def trusted_comments
    @trusted_comments ||= Prompts::BuildForIssue.fetch_trusted_comments(
      github_client: github_client,
      repo: project.full_name,
      number: issue.github_number,
      project: project,
      max_comments: max_comments,
      comments: issue_comments
    )
  end

  def max_comments
    @max_comments ||= user_settings&.max_prompt_comments || Prompts::BuildForIssue::DEFAULT_MAX_COMMENTS
  end

  def max_comment_length
    @max_comment_length ||= user_settings&.max_comment_length || Prompts::BuildForIssue::DEFAULT_MAX_COMMENT_LENGTH
  end

  def user_settings
    @user_settings ||= AgentRuns::UserSettingsResolver.call(project: project, strict: false)
  end

  def untrusted_comment_count
    @untrusted_comment_count ||= issue_comments.count do |comment|
      !PromptAssembly::Trust.human_trusted?(project, comment.user&.login)
    end
  end
end
