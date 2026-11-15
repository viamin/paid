# frozen_string_literal: true

module WorkItems
  # Composes the task prompt for a Paid run started from a unified work item.
  # Imported tracker text is untrusted: only comments admitted through
  # WorkItems::Trust::Admit reach the prompt. GitHub-sourced content is never
  # admitted here; it stays behind the existing GitHub-user allowlist and
  # `issue.trusted?` gate.
  #
  # @spec UNIFIED-WORK-ITEMS-005 UNIFIED-WORK-ITEMS-009
  class BuildRunPrompt
    DEFAULT_MAX_COMMENTS = 20
    DEFAULT_MAX_COMMENT_LENGTH = 2000

    def self.call(...) = new(...).call

    def initialize(work_item:, project:, comments: nil, max_comments: DEFAULT_MAX_COMMENTS,
      max_comment_length: DEFAULT_MAX_COMMENT_LENGTH)
      @work_item = work_item
      @project = project
      @comments = comments
      @max_comments = max_comments
      @max_comment_length = max_comment_length
    end

    def call
      [ task_section, conversation_section ].compact_blank.join("\n")
    end

    private

    attr_reader :work_item, :project, :max_comments, :max_comment_length

    def task_section
      identifier = work_item.raw_payload["identifier"].presence || work_item.external_id
      [
        "# Task", "",
        "You are working on the following #{work_item.provider} ticket:", "",
        "**#{work_item.title}** (#{identifier})", "",
        work_item.body.to_s
      ].join("\n")
    end

    # Admission happens per comment through the provider-neutral trust gate;
    # synchronized text never becomes trusted merely because it was imported.
    def conversation_section
      return "" if admitted_comments.empty?

      bodies = admitted_comments.map do |comment|
        body = comment[:body].to_s
        body = "#{body[0, max_comment_length]}… [truncated]" if body.length > max_comment_length
        "- #{comment[:author_external_id]}: #{body}"
      end

      [
        "# Conversation Comments", "",
        "Comments from trusted tracker identities:", "",
        bodies.join("\n"), "",
        "Address any actionable requests in these comments.", ""
      ].join("\n")
    end

    def admitted_comments
      return [] if max_comments <= 0

      candidates.reverse_each.filter_map do |comment|
        next unless admit?(comment)

        comment
      end.first(max_comments).reverse
    end

    def admit?(comment)
      WorkItems::Trust::Admit.trusted?(
        project: project,
        provider: work_item.provider,
        identity_type: comment[:author_identity_type].to_s.presence || "user",
        external_id: comment[:author_external_id].to_s
      )
    end

    def candidates
      comments = @comments || payload_comments
      comments.map do |comment|
        {
          author_external_id: author_id(comment),
          author_identity_type: comment[:author_identity_type] || comment["author"]&.dig("type") || "user",
          body: comment[:body] || comment["body"]
        }
      end.select { |comment| comment[:author_external_id].present? && comment[:body].present? }
    end

    # Structural mapping of comments retained on the raw payload; Phase 2
    # synchronization populates them under the "comments" key.
    def payload_comments
      Array(work_item.raw_payload["comments"])
    end

    def author_id(comment)
      comment[:author_external_id] || comment.dig("author", "id") || comment.dig("creator", "id") ||
        comment.dig("user", "id")
    end
  end
end
