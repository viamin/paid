# frozen_string_literal: true

module PromptReviews
  # Supersedes a pending evolved prompt version with a reviewer-edited variant.
  # Because PromptVersion content is immutable after creation, editing is
  # modelled as: create a new pending version (parent = old) with the edited
  # template, and reject the old version with a "superseded" note.
  #
  # @example
  #   PromptReviews::Edit.call(
  #     prompt_version: evolved_version,
  #     reviewer: current_user,
  #     attributes: { template: "Refined template", change_notes: "Tightened wording" }
  #   )
  class Edit
    attr_reader :prompt_version, :reviewer, :attributes

    def initialize(prompt_version:, reviewer:, attributes:)
      @prompt_version = prompt_version
      @reviewer = reviewer
      @attributes = attributes || {}
    end

    def self.call(...)
      new(...).edit
    end

    def edit
      validate!

      new_version = nil
      prompt = prompt_version.prompt
      ActiveRecord::Base.transaction do
        new_version = prompt.create_pending_version!(
          template: attributes.fetch(:template, prompt_version.template),
          system_prompt: attributes.fetch(:system_prompt, prompt_version.system_prompt),
          variables: attributes.fetch(:variables, prompt_version.variables),
          change_notes: attributes[:change_notes].presence ||
            "Reviewer-edited variant of v#{prompt_version.version}",
          created_by: "reviewer",
          created_by_user: reviewer,
          parent_version: prompt_version
        )
        prompt_version.update!(
          review_status: "rejected",
          reviewed_by_user: reviewer,
          reviewed_at: Time.current,
          review_notes: superseded_note(new_version)
        )
      end
      new_version
    end

    private

    def validate!
      raise ArgumentError, "reviewer is required" unless reviewer
      raise ArgumentError, "prompt version is not pending review" unless prompt_version.pending_review?
      template = attributes[:template].to_s
      raise ArgumentError, "template is required" if template.strip.empty?
    end

    def superseded_note(new_version)
      base = "Superseded by v#{new_version.version} (reviewer edit)."
      extra = attributes[:review_notes].to_s.strip
      extra.empty? ? base : "#{base} #{extra}"
    end
  end
end
