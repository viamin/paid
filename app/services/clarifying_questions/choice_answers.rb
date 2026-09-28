# frozen_string_literal: true

module ClarifyingQuestions
  # Server-side counterpart to the click-to-answer widget (OPERATOR-INBOX-012).
  #
  # The widget composes each choice answer client-side into one hidden
  # `answers[]` input as human-readable lines:
  #
  #   SQLite (local file, zero setup)
  #   Other: Redis if the team prefers
  #   Details: needs ops review
  #
  # The server never trusts those composed strings. `error_for` re-parses the
  # question with `ClarifyingQuestions::Choices` and rejects answers whose
  # selections are not offered options or a specified "Other". Questions whose
  # parser result is nil (free text) skip validation — the textarea answer is
  # authoritative as typed.
  #
  # Chat answers (QUESTION-EXPLORATION-016) are composed by the assistant from
  # the conversation, not by the widget, so a selection is accepted in any
  # spelling that still unambiguously picks an offered option: the canonical
  # line (optionally with appended rationale), the marker-prefixed echo of the
  # rendered question, the bare option label, or the option's 1-based number
  # or letter. The offered-option invariant of the tamper guard is unchanged.
  # @spec OPERATOR-INBOX-012
  # @spec QUESTION-EXPLORATION-016
  module ChoiceAnswers
    # A bare "Other:" with no following whitespace is NOT an Other line: it
    # stays a selection so validation rejects it as a non-offered option. The
    # `\s+` requirement is what separates "Other:" (forged marker) from
    # "Other: " (a specified-but-empty Other, rejected by its own message).
    OTHER_LINE_PATTERN = /\AOther:\s+(.*)\z/.freeze
    DETAILS_LINE_PATTERN = /\ADetails:\s+(.*)\z/.freeze
    # Leading choice-marker spellings a chat answer may echo from the
    # rendered question: `- ( ) `, `( ) `, `- [ ] `, `[x] `, and `- [x] `,
    # plus the bare `- ` Markdown list marker that wraps the option line the
    # prompt actually renders. The dash variant is greedy with `?`/backtrack
    # so `- ( ) Label ...` still peels off the checkbox marker first.
    MARKER_PREFIX_PATTERN = /\A(?:-\s*)?(?:\(\s*\)|\[\s*[xX]?\s*\])?\s+/.freeze

    module_function

    # Serializes one offered option into the line the widget composes and the
    # server validates selections against.
    def option_line(label:, text:)
      "#{label} (#{text})"
    end

    # Splits a serialized widget answer into its component lines. Lines are
    # matched raw (not pre-stripped) so trailing whitespace after the Other
    # marker still counts as an empty specification rather than vanishing.
    def parse(answer:)
      selections = []
      others = []
      details = []

      answer.to_s.split("\n", -1).each do |line|
        next if line.strip.empty?

        if (other = line.match(OTHER_LINE_PATTERN))
          others << other[1].strip
        elsif (detail = line.match(DETAILS_LINE_PATTERN))
          details << detail[1].strip
        else
          selections << line.strip
        end
      end

      { selections: selections, others: others, details: details }
    end

    # Returns nil when the answer is acceptable for this question (or when the
    # question has no parsed choices and must not be validated); otherwise an
    # operator-facing error string, prefixed with the answer position when
    # given.
    def error_for(question:, answer:, position: nil)
      choices = Choices.call(question: question)
      return nil if choices.nil?
      return nil if answer.to_s.strip.empty?

      parsed = parse(answer: answer)

      not_offered = parsed[:selections].reject { |selection| offered_selection?(selection, choices:) }
      if not_offered.any?
        return format_error("#{not_offered.first.inspect} isn't one of the offered options.", position)
      end
      if parsed[:others].size > 1
        return format_error("Answers may include only one Other response.", position)
      end
      if parsed[:others] == [ "" ]
        return format_error("Selecting Other needs detail - describe your answer in the detail field.", position)
      end

      selected_count = parsed[:selections].size + parsed[:others].size
      if selected_count.zero?
        return format_error("Choice answers must select at least one option or Other.", position)
      end
      if choices[:type] == :single && selected_count > 1
        return format_error("Single-choice answers must select exactly one option or Other.", position)
      end
      if parsed[:others].any? && parsed[:details].any?
        return format_error("Details cannot accompany Other - fold the text into the Other response.", position)
      end

      nil
    end

    # True when a selection line picks one of the question's offered options
    # in any accepted spelling: the canonical `Label (text)` line or the
    # rendered `Label) text` echo (either may carry appended rationale), the
    # bare label, the 1-based number, or the letter. Matching is
    # case-insensitive; the label and the identifiers match the whole line so
    # they cannot be stretched into unrelated prose.
    def offered_selection?(selection, choices:)
      cleaned = selection.sub(MARKER_PREFIX_PATTERN, "").downcase
      choices[:options].each_with_index.any? do |option, index|
        exact_matches = [ option[:label], (index + 1).to_s, (65 + index).chr ].map(&:downcase)
        next true if exact_matches.include?(cleaned)

        cleaned.start_with?(
          option_line(label: option[:label], text: option[:text]).downcase,
          "#{option[:label]}) #{option[:text]}".downcase
        )
      end
    end

    def format_error(message, position)
      position ? "Answer #{position}: #{message}" : message
    end
  end
end
