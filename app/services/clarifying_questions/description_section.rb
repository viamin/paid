# frozen_string_literal: true

module ClarifyingQuestions
  # Reads and writes clarifying-question sections in an issue or PR description.
  # Two paired sections are supported in quiet mode:
  #
  #   <!-- paid:clarifying-questions -->
  #   ## Clarifying questions
  #   <!-- paid:clarifying-questions-digest:abc12345 -->
  #   1. ...
  #   2. ...
  #   <!-- /paid:clarifying-questions -->
  #
  #   <!-- paid:clarifying-answers -->
  #   ## Clarifying question answers
  #   <!-- paid:clarifying-answers-digest:abc12345 -->
  #   ...
  #   <!-- /paid:clarifying-answers -->
  #
  # The digest is a stable hash of the normalized question text so the
  # description channel can match answers to the questions they answer
  # without relying on `comment.created_at`. Sections that omit the digest
  # are tolerated on read so a section written by an older tool still
  # resolves; the digest is only used to disambiguate a current set of
  # questions from a prior one when both happen to live in the description.
  #
  # Body editing is the permitted channel in quiet mode (`QUIET-MODE-009`,
  # `QUIET-MODE-010`, `QUIET-MODE-011`); the helpers here only manipulate
  # text in memory — callers are responsible for issuing `update_issue` /
  # `update_pull_request` against the project-scoped GitHub client.
  module DescriptionSection
    QUESTIONS_OPEN_MARKER = "<!-- paid:clarifying-questions -->"
    QUESTIONS_CLOSE_MARKER = "<!-- /paid:clarifying-questions -->"
    ANSWERS_OPEN_MARKER = "<!-- paid:clarifying-answers -->"
    ANSWERS_CLOSE_MARKER = "<!-- /paid:clarifying-answers -->"
    QUESTIONS_DIGEST_PREFIX = "<!-- paid:clarifying-questions-digest:"
    ANSWERS_DIGEST_PREFIX = "<!-- paid:clarifying-answers-digest:"
    DIGEST_LINE_PATTERN = /<!--\s*paid:clarifying-(?:questions|answers)-digest:([a-f0-9]+)\s*-->/
    # Headings chosen to match the comment-side rendering so the description
    # surface mirrors what operators used to see in the enhancement comment.
    QUESTIONS_HEADING = "## Clarifying questions"
    ANSWERS_HEADING = "## Clarifying question answers"

    QUESTIONS_SECTION_PATTERN = /
      <!--\s*paid:clarifying-questions\s*-->\s*\n
      (.*?)
      <!--\s*\/paid:clarifying-questions\s*-->
    /xm.freeze

    ANSWERS_SECTION_PATTERN = /
      <!--\s*paid:clarifying-answers\s*-->\s*\n
      (.*?)
      <!--\s*\/paid:clarifying-answers\s*-->
    /xm.freeze

    Result = Struct.new(:questions, :digest, :raw_body, keyword_init: true) do
      def any? = questions.any?

      def present? = questions.any?
    end

    module_function

    # Parses clarifying questions out of a description body. Returns a Result
    # whose `#questions` is the array of normalized question strings (empty
    # when the body has no section) and whose `#digest` is the stable digest
    # embedded in the section's digest comment, or `nil` when no digest is
    # present.
    def parse_questions(body)
      match = body.to_s.match(QUESTIONS_SECTION_PATTERN)
      return Result.new(questions: [], digest: nil, raw_body: body.to_s) unless match

      inner = match[1].to_s
      Result.new(
        questions: numbered_items(inner),
        digest: extract_digest(inner),
        raw_body: match[0]
      )
    end

    # Parses clarifying answers out of a description body. Returns a
    # Struct-shaped result with the inner section body, the embedded digest,
    # and the full matched block (including markers). The full block is what
    # `replace_answers_section` needs to swap the answers block without
    # disturbing the rest of the description.
    def parse_answers(body)
      match = body.to_s.match(ANSWERS_SECTION_PATTERN)
      return nil unless match

      {
        inner: match[1].to_s,
        digest: extract_digest(match[1].to_s),
        block: match[0]
      }
    end

    # Replaces the existing questions section (if any) with a new one whose
    # body is the supplied numbered list. If the body has no section yet the
    # section is appended at the end. Existing human-written content outside
    # the section is preserved unchanged.
    def replace_questions_section(body:, questions:)
      new_block = build_questions_block(questions: questions)
      wrapped_body = body.to_s

      if wrapped_body.match?(QUESTIONS_SECTION_PATTERN)
        wrapped_body.sub(QUESTIONS_SECTION_PATTERN) { new_block }
      else
        append_section(wrapped_body, new_block)
      end
    end

    # Replaces the existing answers section (if any) with a new one whose
    # body is the supplied answer text. If the body has no section yet the
    # section is appended at the end. Existing human-written content outside
    # the section is preserved unchanged.
    def replace_answers_section(body:, answers_block:, digest:)
      new_block = build_answers_block(answers_block: answers_block, digest: digest)

      if body.to_s.match?(ANSWERS_SECTION_PATTERN)
        body.sub(ANSWERS_SECTION_PATTERN) { new_block }
      else
        append_section(body.to_s, new_block)
      end
    end

    # Computes the stable question-set digest for a list of normalized
    # question strings. The digest is what links a questions section to its
    # matching answers section without relying on `comment.created_at`
    # timestamps (#4236, `QUIET-MODE-011`). The exact shape is private;
    # callers should treat it as an opaque token.
    def digest_for(questions)
      joined = Array(questions).map { |question| question.to_s.strip }.join("\n")
      Digest::SHA256.hexdigest(joined)[0, 16]
    end

    # Builds the markdown body of the questions section, excluding the
    # enclosing HTML markers. Mirrors the comment-side rendering: a heading
    # + numbered list.
    def build_questions_inner(questions:, digest:)
      lines = [ QUESTIONS_HEADING, "" ]
      lines << "#{QUESTIONS_DIGEST_PREFIX}#{digest} -->" if digest
      questions.each_with_index do |question, index|
        lines << "#{index + 1}. #{question}"
      end
      lines.join("\n")
    end

    # Builds the markdown body of the answers section, excluding the
    # enclosing HTML markers. Freeform notes (when present) are kept under
    # the FREEFORM_NOTES_MARKER so `AnswerPairs` does not fold them into
    # the last A line.
    def build_answers_inner(answers_block:, digest:)
      lines = [ ANSWERS_HEADING, "" ]
      lines << "#{ANSWERS_DIGEST_PREFIX}#{digest} -->" if digest
      lines << answers_block.to_s
      lines.join("\n")
    end

    def build_questions_block(questions:, digest: nil)
      digest ||= digest_for(questions)
      inner = build_questions_inner(questions: questions, digest: digest)
      "#{QUESTIONS_OPEN_MARKER}\n#{inner}\n#{QUESTIONS_CLOSE_MARKER}"
    end

    def build_answers_block(answers_block:, digest:)
      inner = build_answers_inner(answers_block: answers_block, digest: digest)
      "#{ANSWERS_OPEN_MARKER}\n#{inner}\n#{ANSWERS_CLOSE_MARKER}"
    end

    # Splits a numbered list out of a section body, reusing the same folding
    # rules as `ClarifyingQuestions::Parse#parse_numbered_items` so a
    # questions list written into the description parses identically to the
    # same list inside an enhancement comment.
    def numbered_items(text)
      questions = []
      current = nil

      text.each_line do |line|
        stripped = line.strip
        next if stripped.empty?
        # Skip the digest comment line so it is not folded into the first
        # question as a leading blob of text.
        next if stripped.match?(DIGEST_LINE_PATTERN)

        if (match = stripped.match(/\A\d+\.\s+(.+)\z/))
          questions << current if current
          current = match[1]
        elsif current.present?
          current += " " + stripped
        end
      end
      questions << current if current

      questions
    end

    def extract_digest(text)
      match = text.to_s.match(DIGEST_LINE_PATTERN)
      match && match[1]
    end

    # Appends a section block to the end of a body, separated by two blank
    # lines. Trailing blank lines are normalized away so the appended block
    # always reads as a discrete section even when the body already ends
    # mid-paragraph.
    def append_section(body, block)
      stripped = body.to_s.sub(/\s*\z/, "")
      return block if stripped.empty?

      "#{stripped}\n\n#{block}\n"
    end
  end
end