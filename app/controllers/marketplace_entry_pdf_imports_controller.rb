# frozen_string_literal: true

class MarketplaceEntryPdfImportsController < ApplicationController
  def new
    @marketplace_entry = build_marketplace_entry
    authorize @marketplace_entry
  end

  def create
    @marketplace_entry = build_marketplace_entry
    authorize @marketplace_entry

    entry = MarketplaceEntries::ImportFromPdf.call(
      account: current_account,
      actor: current_user,
      params: marketplace_entry_pdf_import_params
    )

    redirect_to marketplace_entry_path(entry), notice: "Marketplace entry created from PDF."
  rescue Knowledge::PdfImports::ImportError, MarketplaceEntries::ImportFromPdf::ImportError => e
    @marketplace_entry.errors.add(:base, e.message)
    render :new, status: :unprocessable_content
  end

  private

  def build_marketplace_entry
    current_account.marketplace_entries.build(
      name: marketplace_entry_pdf_import_params[:name],
      entry_type: marketplace_entry_pdf_import_params[:entry_type].presence || "skill",
      description: marketplace_entry_pdf_import_params[:description],
      usage_guidance: marketplace_entry_pdf_import_params[:usage_guidance],
      provider_format: "canonical_v1",
      team_scope: "account",
      status: marketplace_entry_pdf_import_params[:status].presence || "draft"
    ).tap do |entry|
      entry.tags_csv = marketplace_entry_pdf_import_params[:tags_csv].to_s
    end
  end

  def marketplace_entry_pdf_import_params
    params.fetch(:marketplace_entry, {}).permit(
      :name, :entry_type, :description, :usage_guidance, :tags_csv, :status, :pdf_file
    )
  end
end
