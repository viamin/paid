# frozen_string_literal: true

# Human review gate for evolved prompt variants.
#
# - `GET /prompt_reviews` (`#queue`) lists all pending versions across the
#   signed-in user's accessible prompts (account-wide queue).
# - Nested `GET /prompts/:prompt_id/reviews` (`#index`) and `:show` let
#   reviewers inspect a pending version alongside its parent (diff + metrics).
# - `POST :approve` / `POST :reject` delegate to the PromptReviews services.
# - `PATCH :update` supersedes a pending version with a reviewer-edited one
#   (content fields are immutable, so editing produces a new pending version
#   with the old one rejected as "superseded").
class PromptReviewsController < ApplicationController
  before_action :set_prompt, only: [ :index, :show, :update, :approve, :reject ]
  before_action :set_prompt_version, only: [ :show, :update, :approve, :reject ]
  skip_after_action :verify_authorized, only: [ :index, :queue ]

  def queue
    account_prompt_ids = policy_scope(Prompt).pluck(:id)
    @prompt_versions = PromptVersion.pending_review
      .where(prompt_id: account_prompt_ids)
      .includes(:prompt, :created_by_user, :parent_version)
      .order(created_at: :desc)
  end

  def index
    @prompt_versions = @prompt.prompt_versions.pending_review
      .includes(:created_by_user, :parent_version)
      .order(created_at: :desc)
  end

  def show
    authorize @prompt, :show?
  end

  def update
    authorize @prompt, :update?

    new_version = PromptReviews::Edit.call(
      prompt_version: @prompt_version,
      reviewer: current_user,
      attributes: edit_params
    )
    redirect_to prompt_review_path(@prompt, new_version),
      notice: "Edited variant saved as v#{new_version.version} (pending review)."
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to prompt_review_path(@prompt, @prompt_version), alert: error_message(e)
  end

  def approve
    authorize @prompt, :update?

    PromptReviews::Approve.call(
      prompt_version: @prompt_version,
      reviewer: current_user,
      notes: review_notes_param
    )
    redirect_to prompt_path(@prompt),
      notice: "v#{@prompt_version.version} approved and promoted to current."
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to prompt_review_path(@prompt, @prompt_version), alert: error_message(e)
  end

  def reject
    authorize @prompt, :update?

    PromptReviews::Reject.call(
      prompt_version: @prompt_version,
      reviewer: current_user,
      notes: review_notes_param
    )
    redirect_to prompt_reviews_path(@prompt),
      notice: "v#{@prompt_version.version} rejected."
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to prompt_review_path(@prompt, @prompt_version), alert: error_message(e)
  end

  private

  def set_prompt
    @prompt = policy_scope(Prompt).find(params[:prompt_id])
  end

  def set_prompt_version
    @prompt_version = @prompt.prompt_versions.find(params[:id])
  end

  def edit_params
    permitted = params.require(:prompt_version)
      .permit(:template, :system_prompt, :change_notes, :review_notes)
    # Preserve parent version variables — reviewers rarely change these and
    # they're stored as structured metadata that doesn't round-trip cleanly
    # through a plain text form input.
    permitted.to_h.symbolize_keys.merge(variables: @prompt_version.variables)
  end

  def review_notes_param
    params.dig(:prompt_version, :review_notes).to_s.strip.presence
  end

  def error_message(error)
    case error
    when ActiveRecord::RecordInvalid then error.record.errors.full_messages.join(", ")
    else error.message
    end
  end
end
