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
  # @spec OPERATOR-INBOX-012
  module ChoiceAnswers
    # A bare "Other:" with no following whitespace is NOT an Other line: it
    # stays a selection so validation rejects it as a non-offered option. The
    # `\s+` requirement is what separates "Other:" (forged marker) from
    # "Other: " (a specified-but-empty Other, rejected by its own message).
    OTHER_LINE_PATTERN = /\AOther:\s+(.*)\z/.freeze
    DETAILS_LINE_PATTERN = /\ADetails:\s+(.*)\z/.freeze

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
      offered = choices[:options].map { |option| option_line(label: option[:label], text: option[:text]) }

      not_offered = parsed[:selections].reject { |selection| offered.include?(selection) }
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

    def format_error(message, position)
      position ? "Answer #{position}: #{message}" : message
    end
  end
end
