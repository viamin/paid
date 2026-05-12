# frozen_string_literal: true

class StrategyReviewsController < ApplicationController
  before_action :set_strategy, only: [ :index, :show, :update, :approve, :reject ]
  before_action :set_strategy_version, only: [ :show, :update, :approve, :reject ]
  skip_after_action :verify_authorized, only: [ :index, :queue ]

  def queue
    account_strategy_ids = reviewable_strategies.pluck(:id)
    @strategy_versions = StrategyVersion.pending_review
      .where(strategy_id: account_strategy_ids)
      .includes(:strategy, :created_by_user, :parent_version)
      .order(created_at: :desc)
  end

  def index
    @strategy_versions = @strategy.pending_reviews
      .includes(:created_by_user, :parent_version)
      .order(created_at: :desc)
  end

  def show
    authorize @strategy, :show?
  end

  def update
    authorize @strategy, :update?

    new_version = StrategyReviews::Edit.call(
      strategy_version: @strategy_version,
      reviewer: current_user,
      attributes: edit_params
    )

    redirect_to strategy_review_path(@strategy, new_version),
      notice: "Edited variant saved as v#{new_version.version} (pending review)."
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to strategy_review_path(@strategy, @strategy_version), alert: error_message(e)
  end

  def approve
    authorize @strategy, :update?

    StrategyReviews::Approve.call(
      strategy_version: @strategy_version,
      reviewer: current_user
    )

    redirect_to strategy_reviews_path(@strategy),
      notice: "v#{@strategy_version.version} approved and promoted to current."
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to strategy_review_path(@strategy, @strategy_version), alert: error_message(e)
  end

  def reject
    authorize @strategy, :update?

    StrategyReviews::Reject.call(
      strategy_version: @strategy_version,
      reviewer: current_user
    )

    redirect_to strategy_reviews_path(@strategy),
      notice: "v#{@strategy_version.version} rejected."
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to strategy_review_path(@strategy, @strategy_version), alert: error_message(e)
  end

  private

  def set_strategy
    @strategy = reviewable_strategies.find(params[:strategy_id])
  end

  def set_strategy_version
    @strategy_version = @strategy.strategy_versions.find(params[:id])
  end

  def reviewable_strategies
    policy_scope(Strategy).where.not(account_id: nil)
  end

  def edit_params
    strategy_version_params = params.require(:strategy_version)
    permitted = strategy_version_params
      .permit(:change_notes, :reasoning)
      .to_h
      .deep_symbolize_keys
    permitted[:content] = normalized_content(strategy_version_params[:content]) if strategy_version_params.key?(:content)
    permitted
  end

  def error_message(error)
    case error
    when ActiveRecord::RecordInvalid then error.record.errors.full_messages.join(", ")
    else error.message
    end
  end

  def normalized_content(content)
    parsed_content =
      case content
      when String then JSON.parse(content)
      when ActionController::Parameters then content.to_unsafe_h
      when Hash, nil then content
      else
        raise ArgumentError, "content must be an object"
      end

    return parsed_content if parsed_content.nil? || parsed_content.is_a?(Hash)

    raise ArgumentError, "content must be an object"
  rescue JSON::ParserError
    raise ArgumentError, "content must be valid JSON"
  end
end
