# frozen_string_literal: true

module StyleGuideAbTests
  class Create
    attr_reader :style_guide, :name, :description, :variant_version_ids, :options

    def initialize(style_guide:, name:, variant_version_ids:, description: nil, **options)
      @style_guide = style_guide
      @name = name
      @description = description
      @variant_version_ids = variant_version_ids
      @options = options
    end

    def self.call(...)
      new(...).create
    end

    def create
      validate!

      ActiveRecord::Base.transaction do
        test = StyleGuideAbTest.create!(
          account: style_guide.account || style_guide.project&.account,
          style_guide: style_guide,
          control_version_id: style_guide.current_version_id,
          name: name,
          description: description,
          status: "draft",
          min_samples_per_variant: options.fetch(:min_samples_per_variant, 30),
          confidence_threshold: options.fetch(:confidence_threshold, 0.95),
          idempotency_key: options[:idempotency_key]
        )

        test.style_guide_ab_test_variants.create!(
          style_guide_version: style_guide.current_version,
          is_control: true
        )

        variant_version_ids.each do |version_id|
          test.style_guide_ab_test_variants.create!(
            style_guide_version: style_guide.style_guide_versions.find(version_id),
            is_control: false
          )
        end

        test
      end
    end

    private

    def validate!
      raise ArgumentError, "style guide must have a current version" unless style_guide.current_version_id
      raise ArgumentError, "at least one variant version is required" if variant_version_ids.empty?
      raise ArgumentError, "maximum #{StyleGuideAbTest::MAX_VARIANTS} variants allowed" if variant_version_ids.size > StyleGuideAbTest::MAX_VARIANTS
      raise ArgumentError, "variant versions must be unique" if variant_version_ids.uniq.size != variant_version_ids.size
      raise ArgumentError, "variant versions cannot include the control version" if variant_version_ids.include?(style_guide.current_version_id)
      raise ArgumentError, "account-scoped ownership is required" if style_guide.account.nil? && style_guide.project&.account.nil?
      raise ArgumentError, "style guide already has a running A/B test for this account" if StyleGuideAbTest.running.where(account: style_guide.account || style_guide.project&.account).exists?

      existing_ids = style_guide.style_guide_versions.where(id: variant_version_ids).pluck(:id)
      missing_ids = variant_version_ids - existing_ids
      return if missing_ids.empty?

      raise ArgumentError, "variant version(s) #{missing_ids.join(', ')} not found for this style guide"
    end
  end
end
