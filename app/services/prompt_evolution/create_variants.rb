# frozen_string_literal: true

module PromptEvolution
  # Persists mutation variants produced by +PromptEvolution::Mutate+ as
  # PromptVersion records. Honors the prompt's review gate:
  #
  # - When +prompt.requires_review+ is true, variants are created as pending
  #   reviews and NOT promoted to current_version. A human must approve via
  #   PromptReviews::Approve before the variant becomes active.
  # - When +prompt.requires_review+ is false (advanced-user opt-out), the
  #   first variant is auto-promoted to current_version and marked approved.
  #
  # @example
  #   mutations = PromptEvolution::Mutate.call(prompt: prompt, ...)
  #   PromptEvolution::CreateVariants.call(
  #     prompt: prompt,
  #     mutations: mutations,
  #     created_by_user: system_user
  #   )
  class CreateVariants
    attr_reader :prompt, :mutations, :created_by_user, :project

    def initialize(prompt:, mutations:, created_by_user: nil, project: nil)
      @prompt = prompt
      @mutations = Array(mutations)
      @created_by_user = created_by_user
      @project = project || prompt.project
    end

    def self.call(...)
      new(...).create
    end

    def create
      return [] if mutations.empty?

      parent = prompt.current_version
      variants = mutations.map do |mutation|
        persist_variant(mutation, parent)
      end

      auto_promote_first(variants) unless prompt.requires_review?
      auto_resume_project(variants) unless prompt.requires_review?
      variants
    end

    private

    def persist_variant(mutation, parent)
      attributes = {
        template: mutation.template,
        system_prompt: parent&.system_prompt,
        variables: parent&.variables || [],
        change_notes: change_notes_for(mutation),
        created_by: "evolution",
        created_by_user: created_by_user,
        parent_version: parent
      }
      # Always start evolved variants as pending so history records the
      # review-workflow lineage; auto-promote flips the first one to approved
      # when the review gate is off.
      prompt.create_pending_version!(attributes)
    end

    def auto_promote_first(variants)
      winner = variants.first
      return unless winner

      prompt.with_lock do
        winner.update!(
          review_status: "approved",
          reviewed_by_user: created_by_user,
          reviewed_at: Time.current,
          review_notes: "Auto-promoted (requires_review disabled)"
        )
        prompt.update!(current_version: winner)
      end
    end

    def change_notes_for(mutation)
      parts = [ "Evolved variant (#{mutation.strategy})" ]
      parts << mutation.reasoning if mutation.reasoning.present?
      parts.join(": ")
    end

    def auto_resume_project(variants)
      return if variants.empty? || project.nil?

      QualityPause::AutoResume.call(
        project: project,
        reason: "prompt_evolution_variant_created",
        metadata: {
          prompt_id: prompt.id,
          variant_version_ids: variants.map(&:id)
        }
      )
    end
  end
end
