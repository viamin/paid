# frozen_string_literal: true

module Api
  class MarketplaceEntriesController < ApplicationController
    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Not found" }, status: :not_found
    end

    rescue_from Pundit::NotAuthorizedError do
      render json: { error: "Forbidden" }, status: :forbidden
    end

    skip_after_action :verify_authorized, only: :index

    def index
      entries = filtered_scope.includes(:current_version).ordered

      render json: {
        entries: entries.map { |entry| index_entry_json(entry) }
      }
    end

    def show
      entry = policy_scope(MarketplaceEntry)
        .includes(:current_version, :marketplace_entry_rules)
        .find(params[:id])
      authorize entry

      render json: show_entry_json(entry)
    end

    private

    def authenticate_user!
      return if user_signed_in?

      render json: { error: "Unauthorized" }, status: :unauthorized
    end

    def filtered_scope
      scope = policy_scope(MarketplaceEntry)
      scope = scope.where(status: params[:status]) if params[:status].present?
      scope = scope.active if params[:status].blank?

      scope
        .with_entry_type(params[:entry_type])
        .with_extension_point(params[:extension_point])
        .with_certification_status(params[:certification_status])
        .tagged_with(params[:tag])
        .search(params[:query])
    end

    def index_entry_json(entry)
      {
        id: entry.id,
        name: entry.name,
        entry_type: entry.entry_type,
        description: entry.description,
        provider: entry.provider,
        provider_format: entry.provider_format,
        status: entry.status,
        tags: entry.tags,
        extension_points: entry.extension_points,
        certification_status: entry.certification_status,
        support_tier: entry.support_tier,
        documentation_url: entry.documentation_url,
        source_code_url: entry.source_code_url,
        current_version: entry.current_version&.yield_self { |version| { id: version.id, version: version.version } },
        updated_at: entry.updated_at.iso8601
      }
    end

    def show_entry_json(entry)
      version = entry.current_version

      index_entry_json(entry).merge(
        usage_guidance: entry.usage_guidance,
        certification_notes: entry.certification_notes,
        added_by_name: entry.added_by_name,
        added_by_email: entry.added_by_email,
        rules: entry.marketplace_entry_rules.ordered.map do |rule|
          {
            mode: rule.mode,
            enabled: rule.enabled,
            rationale: rule.rationale,
            conditions: rule.conditions
          }
        end,
        current_version: version && {
          id: version.id,
          version: version.version,
          changelog: version.changelog,
          canonical_artifact: version.canonical_artifact,
          renderers: version.renderers,
          compatibility_constraints: version.compatibility_constraints,
          review_metadata: version.review_metadata,
          created_at: version.created_at.iso8601,
          updated_at: version.updated_at.iso8601
        }
      )
    end
  end
end
