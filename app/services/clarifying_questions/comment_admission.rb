# frozen_string_literal: true

module ClarifyingQuestions
  # Decides whether a GitHub issue comment may enter the clarifying-questions
  # flow. Admits trusted human collaborators OR Paid's own enhancement/answer
  # marker comments authored by the project's GitHub App bot — app-backed
  # projects post those as the bot, which Project#trusted_github_user?
  # deliberately excludes as an untrusted prompt-injection channel.
  #
  # Scoped to clarifying questions only: it never broadens the comment trust
  # used for arbitrary conversation in prompts (see
  # Prompts::BuildForIssue.fetch_trusted_comments). Safe because the bot login
  # is unspoofable — only Paid's GitHub App can author content as it — and the
  # admitted content originates from Paid itself (LLM-generated questions, or
  # answers submitted by an authenticated operator with update access).
  module CommentAdmission
    module_function

    def admissible?(project:, comment:)
      login = comment.user&.login
      project.trusted_github_user?(login) || paid_marker_comment?(project, login, comment)
    end

    def paid_marker_comment?(project, login, comment)
      return false unless project.paid_bot_author?(login)

      body = comment.body.to_s
      body.include?(Parse::ENHANCEMENT_MARKER) || body.include?(Load::ANSWER_MARKER)
    end
  end
end
