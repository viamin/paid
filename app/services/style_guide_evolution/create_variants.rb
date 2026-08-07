# frozen_string_literal: true

module StyleGuideEvolution
  class CreateVariants
    attr_reader :style_guide, :mutations, :idempotency_key

    def initialize(style_guide:, mutations:, idempotency_key: nil)
      @style_guide = style_guide
      @mutations = Array(mutations)
      @idempotency_key = idempotency_key
    end

    def self.call(...)
      new(...).create
    end

    # @spec STYLE-GUIDE-EVOLUTION-008
    def create
      return [] if mutations.empty?

      parent = style_guide.current_version
      mutations.map do |mutation|
        create_variant(mutation, parent)
      end
    end

    private

    def create_variant(mutation, parent)
      attributes = {
        raw_content: mutation.raw_content,
        created_by: "evolution",
        change_notes: [ "Evolved variant (#{mutation.strategy})", mutation.reasoning ].compact.join(": "),
        parent_version: parent,
        review_status: "approved"
      }

      if idempotency_key
        existing = style_guide.style_guide_versions.find_by(
          idempotency_key: Activities::IdempotencyKey.compute(idempotency_key, mutation.raw_content, mutation.strategy)
        )
        return existing if existing
      end

      style_guide.with_lock do
        next_version = (style_guide.style_guide_versions.maximum(:version) || 0) + 1
        style_guide.style_guide_versions.create!(
          **attributes,
          version: next_version,
          idempotency_key: idempotency_key ? Activities::IdempotencyKey.compute(idempotency_key, mutation.raw_content, mutation.strategy) : nil
        )
      end
    end
  end
end
