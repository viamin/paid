# frozen_string_literal: true

module MarketplaceEntries
  class Upsert
    attr_reader :entry, :params, :actor

    def initialize(entry:, params:, actor:)
      @entry = entry
      @params = params
      @actor = actor
    end

    def self.call(...)
      new(...).call
    end

    def call
      assign_metadata
      assign_virtual_fields
      return false unless parsed_artifact_payloads

      ActiveRecord::Base.transaction do
        entry.save!
        upsert_version!
        upsert_rules!
      end

      true
    rescue ActiveRecord::RecordInvalid => e
      entry.errors.merge!(e.record.errors) if e.record != entry
      false
    end

    private

    def assign_metadata
      entry.assign_attributes(
        name: params[:name],
        entry_type: params[:entry_type],
        description: params[:description],
        provider: params[:provider],
        provider_format: params[:provider_format].presence || "canonical_v1",
        usage_guidance: params[:usage_guidance],
        extension_points: normalize_string_list(params[:extension_points]),
        certification_status: params[:certification_status].presence || "uncertified",
        support_tier: params[:support_tier].presence || "community",
        documentation_url: params[:documentation_url],
        source_code_url: params[:source_code_url],
        certification_notes: params[:certification_notes],
        team_scope: params[:team_scope].presence || "account",
        status: params[:status].presence || "draft"
      )
      entry.tags_csv = params[:tags_csv].to_s
      assign_original_publisher_metadata
    end

    def assign_virtual_fields
      entry.canonical_artifact_json = params[:canonical_artifact_json].to_s
      entry.renderers_json = params[:renderers_json].to_s
      entry.compatibility_constraints_json = params[:compatibility_constraints_json].to_s
      entry.review_metadata_json = params[:review_metadata_json].to_s
      entry.automatic_enabled = params[:automatic_enabled]
      entry.automatic_conditions_json = params[:automatic_conditions_json].to_s
      entry.automatic_rationale = params[:automatic_rationale].to_s
      entry.team_default_enabled = params[:team_default_enabled]
      entry.team_default_conditions_json = params[:team_default_conditions_json].to_s
      entry.team_default_rationale = params[:team_default_rationale].to_s
    end

    def assign_original_publisher_metadata
      if entry.added_by_name.blank?
        entry.added_by_name = params[:added_by_name].presence || actor&.name.presence || actor&.email.to_s
      end
      if entry.added_by_email.blank?
        entry.added_by_email = params[:added_by_email].presence || actor&.email.to_s
      end
    end

    def parsed_artifact_payloads
      @canonical_artifact = parse_required_object(:canonical_artifact_json, :canonical_artifact)
      @renderers = parse_optional_object(:renderers_json, :renderers)
      validate_renderer_payloads if @renderers
      @compatibility_constraints = parse_optional_object(:compatibility_constraints_json, :compatibility_constraints)
      @review_metadata = parse_optional_object(:review_metadata_json, :review_metadata)
      @automatic_conditions = parse_optional_object(:automatic_conditions_json, :automatic_conditions)
      @team_default_conditions = parse_optional_object(:team_default_conditions_json, :team_default_conditions)

      entry.errors.empty?
    end

    def upsert_version!
      current_version = entry.current_version
      version_attributes = {
        changelog: params[:changelog],
        canonical_artifact: @canonical_artifact,
        renderers: @renderers || {},
        compatibility_constraints: @compatibility_constraints || {},
        review_metadata: @review_metadata || {}
      }

      return if current_version.present? && same_version_payload?(current_version, version_attributes)

      entry.create_version!(version_attributes)
    end

    def upsert_rules!
      if automatic_rule_params_submitted?
        upsert_rule!(
          mode: "automatic",
          enabled_param: params[:automatic_enabled],
          conditions: @automatic_conditions || {},
          rationale: params[:automatic_rationale]
        )
      end
      if team_default_rule_params_submitted?
        upsert_rule!(
          mode: "team_default",
          enabled_param: params[:team_default_enabled],
          conditions: @team_default_conditions || {},
          rationale: params[:team_default_rationale]
        )
      end
    end

    def automatic_rule_params_submitted?
      rule_params_submitted?(:automatic_enabled, :automatic_conditions_json, :automatic_rationale)
    end

    def team_default_rule_params_submitted?
      rule_params_submitted?(:team_default_enabled, :team_default_conditions_json, :team_default_rationale)
    end

    def rule_params_submitted?(*keys)
      keys.any? { |key| params.key?(key) || params.key?(key.to_s) }
    end

    def upsert_rule!(mode:, enabled_param:, conditions:, rationale:)
      rule = entry.marketplace_entry_rules.find_or_initialize_by(mode:)
      enabled = ActiveModel::Type::Boolean.new.cast(enabled_param)

      if !enabled && conditions.blank? && rationale.blank? && !rule.persisted?
        return
      end

      rule.assign_attributes(
        enabled: enabled,
        position: MarketplaceEntryRule::MODES.index(mode) || 0,
        conditions: conditions,
        rationale: rationale
      )
      rule.save!
    end

    def same_version_payload?(current_version, attributes)
      current_version.changelog.to_s == attributes[:changelog].to_s &&
        current_version.canonical_artifact == attributes[:canonical_artifact] &&
        current_version.renderers == attributes[:renderers] &&
        current_version.compatibility_constraints == attributes[:compatibility_constraints] &&
        current_version.review_metadata == attributes[:review_metadata]
    end

    def parse_required_object(source_attribute, target_attribute)
      parsed = parse_optional_object(source_attribute, target_attribute)
      return parsed unless parsed.nil?

      entry.errors.add(target_attribute, "must be present")
      nil
    end

    def parse_optional_object(source_attribute, target_attribute)
      value = entry.public_send(source_attribute)
      parsed = JsonParser.parse_json(value, default: {})
      if parsed == :invalid_json
        entry.errors.add(target_attribute, "must be valid JSON")
        return nil
      end

      if !parsed.is_a?(Hash)
        entry.errors.add(target_attribute, "must be a JSON object")
        return nil
      end

      parsed
    end

    def validate_renderer_payloads
      invalid_provider_keys = @renderers.each_with_object([]) do |(provider_key, payload), keys|
        keys << provider_key unless payload.is_a?(Hash)
      end
      return if invalid_provider_keys.empty?

      entry.errors.add(
        :renderers,
        "must map provider keys to JSON objects (invalid: #{invalid_provider_keys.join(', ')})"
      )
    end

    def normalize_string_list(value)
      Array(value).map(&:to_s).map(&:strip).reject(&:blank?).uniq
    end
  end
end
