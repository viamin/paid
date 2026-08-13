# frozen_string_literal: true

class MarketplaceEntriesController < ApplicationController
  skip_after_action :verify_authorized, only: :index

  before_action :set_marketplace_entry, only: [ :show, :edit, :update, :destroy ]

  def index
    base_scope = policy_scope(MarketplaceEntry).includes(:current_version)
    @q = base_scope.ransack(params[:q])
    @q.sorts = [ "updated_at desc", "id desc" ] if @q.sorts.empty?
    @pagy, @marketplace_entries = pagy(@q.result)
  end

  def show
    authorize @marketplace_entry
  end

  def new
    @marketplace_entry = current_account.marketplace_entries.build(
      provider_format: "canonical_v1",
      team_scope: "account",
      status: "draft",
      certification_status: "uncertified",
      support_tier: "community"
    )
    authorize @marketplace_entry
  end

  def create
    @marketplace_entry = current_account.marketplace_entries.build
    authorize @marketplace_entry

    if MarketplaceEntries::Upsert.call(entry: @marketplace_entry, params: marketplace_entry_params, actor: current_user)
      redirect_to marketplace_entry_path(@marketplace_entry), notice: "Marketplace entry created."
    else
      render :new, status: :unprocessable_content
    end
  end

  def edit
    authorize @marketplace_entry
    preload_form_fields
  end

  def update
    authorize @marketplace_entry

    if MarketplaceEntries::Upsert.call(entry: @marketplace_entry, params: marketplace_entry_params, actor: current_user)
      redirect_to marketplace_entry_path(@marketplace_entry), notice: "Marketplace entry updated."
    else
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    authorize @marketplace_entry

    if @marketplace_entry.destroy
      redirect_to marketplace_entries_path, notice: "Marketplace entry removed."
    else
      redirect_to marketplace_entry_path(@marketplace_entry), alert: @marketplace_entry.errors.full_messages.to_sentence
    end
  end

  private

  def set_marketplace_entry
    @marketplace_entry = policy_scope(MarketplaceEntry)
      .includes(:current_version, :marketplace_entry_rules)
      .find(params[:id])
  end

  def marketplace_entry_params
    permitted = [
      :name, :entry_type, :description, :provider, :provider_format,
      :usage_guidance, :added_by_name, :added_by_email, :tags_csv, :team_scope,
      :status, :certification_status, :support_tier, :documentation_url,
      :source_code_url, :certification_notes, :changelog, :canonical_artifact_json,
      :renderers_json, :compatibility_constraints_json, :review_metadata_json
    ]
    permitted << { extension_points: [] }
    if marketplace_rule_management_allowed?
      permitted.concat(
        %i[
          automatic_enabled automatic_conditions_json automatic_rationale
          team_default_enabled team_default_conditions_json team_default_rationale
        ]
      )
    end

    params.require(:marketplace_entry).permit(*permitted)
  end

  def preload_form_fields
    version = @marketplace_entry.current_version
    rules_by_mode = @marketplace_entry.marketplace_entry_rules.index_by(&:mode)
    automatic_rule = rules_by_mode["automatic"]
    team_default_rule = rules_by_mode["team_default"]

    @marketplace_entry.canonical_artifact_json = JSON.pretty_generate(version&.canonical_artifact || {})
    @marketplace_entry.renderers_json = JSON.pretty_generate(version&.renderers || {})
    @marketplace_entry.compatibility_constraints_json = JSON.pretty_generate(version&.compatibility_constraints || {})
    @marketplace_entry.review_metadata_json = JSON.pretty_generate(version&.review_metadata || {})
    @marketplace_entry.automatic_enabled = automatic_rule&.enabled
    @marketplace_entry.automatic_conditions_json = JSON.pretty_generate(automatic_rule&.conditions || {})
    @marketplace_entry.automatic_rationale = automatic_rule&.rationale
    @marketplace_entry.team_default_enabled = team_default_rule&.enabled
    @marketplace_entry.team_default_conditions_json = JSON.pretty_generate(team_default_rule&.conditions || {})
    @marketplace_entry.team_default_rationale = team_default_rule&.rationale
  end

  def marketplace_rule_management_allowed?
    policy(@marketplace_entry).manage_rules?
  end
end
