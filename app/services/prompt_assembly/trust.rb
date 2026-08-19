# frozen_string_literal: true

module PromptAssembly
  # Centralized trust policy for prompt inputs.
  #
  # @spec PROMPT-ASSEMBLY-001, PROMPT-ASSEMBLY-002, PROMPT-ASSEMBLY-007
  #
  # Single source of truth for whether a GitHub-authored input may reach an
  # agent prompt. Reuses the existing allowlist predicates rather than
  # inventing a second trust policy:
  #
  # - Project#trusted_github_user? — human collaborator allowlist
  # - Project#paid_bot_author?     — Paid's own GitHub App bot identity
  # - recognized Paid marker bodies — content Paid itself authored
  module Trust
    # Markers Paid itself injects as its own bot. These re-admit structured
    # content (enhancement questions, clarifying answers, review feedback)
    # that Project#trusted_github_user? deliberately excludes because it is
    # authored by the bot, not a human.
    PAID_ADMITTED_MARKERS = [
      ClarifyingQuestions::Parse::ENHANCEMENT_MARKER,
      ClarifyingQuestions::Load::ANSWER_MARKER,
      Github::ReviewMarker::PAID_REVIEW_MARKER
    ].freeze

    module_function

    # Whether +login+ is an allowlisted human collaborator.
    def human_trusted?(project, login)
      project.trusted_github_user?(login)
    end

    # Whether a PR review-thread author is prompt-eligible. Review threads can
    # report GitHub App authors as the bare app slug, so use the project's
    # enabled review-bot login set in addition to the human allowlist.
    def review_thread_author_trusted?(project, login)
      return false if login.blank?

      human_trusted?(project, login) ||
        project.respond_to?(:enabled_review_bot_logins) &&
          project.enabled_review_bot_logins.include?(login.to_s.downcase)
    end

    # Whether +login+ is Paid's own GitHub App bot identity.
    def paid_bot?(project, login)
      project.paid_bot_author?(login)
    end

    # Paid-authored status comments that must never be fed back as actionable
    # feedback (agent-update summaries, escalation notes).
    def paid_status_comment?(body)
      Activities::CompleteExistingPrRunActivity.agent_update_comment?(body) ||
        body.to_s.include?(Activities::MarkEscalatedActivity::COMMENT_MARKER)
    end

    # Whether +body+ carries a recognized Paid-generated marker.
    def paid_marker?(body)
      text = body.to_s
      PAID_ADMITTED_MARKERS.any? { |marker| text.include?(marker) }
    end

    # A Paid-authored marker comment: bot identity + recognized marker.
    def paid_marker_comment?(project, login, body)
      paid_bot?(project, login) && paid_marker?(body)
    end

    # Whether a GitHub comment is prompt-eligible: allowlisted human (excluding
    # Paid status comments) or Paid-authored marker comment.
    def comment_trusted?(project, comment)
      login = comment&.user&.login
      body = comment.respond_to?(:body) ? comment.body : nil

      (human_trusted?(project, login) && !paid_status_comment?(body)) ||
        paid_marker_comment?(project, login, body)
    end

    # Classify a GitHub comment into a TrustedInput. Fails closed: content
    # whose author cannot be proven trusted is excluded, never trusted.
    def classify_comment(project, comment, kind: :comment, source: :conversation)
      login = comment&.user&.login
      body = comment.respond_to?(:body) ? comment.body : nil

      if comment_trusted?(project, comment)
        TrustedInput.new(kind: kind, source: source, login: login, body: body, trust: :trusted)
      else
        TrustedInput.new(
          kind: kind,
          source: source,
          login: login,
          body: nil,
          trust: :excluded,
          exclusion_reason: login.present? ? "author_not_in_allowlist" : "missing_author_identity"
        )
      end
    end
  end
end
