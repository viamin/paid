# frozen_string_literal: true

class AbTestsController < ApplicationController
  before_action :set_ab_test, only: [ :show, :edit, :update, :destroy, :start, :complete, :cancel, :promote_winner ]
  skip_after_action :verify_authorized, only: :index

  def index
    base_scope = policy_scope(AbTest).includes(:prompt, :ab_test_variants)
    @q = base_scope.ransack(params[:q])
    @q.sorts = "created_at desc" if @q.sorts.empty?
    @pagy, @ab_tests = pagy(@q.result)
  end

  def show
    authorize @ab_test
    @analysis = AbTests::Analyze.call(ab_test: @ab_test) if @ab_test.running? || @ab_test.completed?
  end

  def new
    @ab_test = AbTest.new
    authorize @ab_test
    @prompts = policy_scope(Prompt).active.includes(:current_version).order(:name)
    @ab_test.ab_test_variants.build if @ab_test.ab_test_variants.empty?
  end

  def create
    @ab_test = AbTest.new(ab_test_params)
    authorize @ab_test

    if @ab_test.save
      redirect_to @ab_test, notice: "A/B test was successfully created."
    else
      @prompts = policy_scope(Prompt).active.includes(:current_version).order(:name)
      render :new, status: :unprocessable_content
    end
  end

  def edit
    authorize @ab_test
    @prompts = policy_scope(Prompt).active.includes(:current_version).order(:name)
    @ab_test.ab_test_variants.build if @ab_test.ab_test_variants.empty?
  end

  def update
    authorize @ab_test

    if @ab_test.update(ab_test_params)
      redirect_to @ab_test, notice: "A/B test was successfully updated."
    else
      @prompts = policy_scope(Prompt).active.includes(:current_version).order(:name)
      render :edit, status: :unprocessable_content
    end
  end

  def destroy
    authorize @ab_test
    @ab_test.destroy!
    redirect_to ab_tests_path, notice: "A/B test was successfully deleted."
  end

  def start
    authorize @ab_test, :update?
    @ab_test.start!
    redirect_to @ab_test, notice: "A/B test has been started."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to @ab_test, alert: e.message
  end

  def complete
    authorize @ab_test, :update?
    @ab_test.complete!
    redirect_to @ab_test, notice: "A/B test has been completed."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to @ab_test, alert: e.message
  end

  def cancel
    authorize @ab_test, :update?
    @ab_test.cancel!
    redirect_to @ab_test, notice: "A/B test has been cancelled."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to @ab_test, alert: e.message
  end

  def promote_winner
    authorize @ab_test, :update?

    if @ab_test.winner_variant.present?
      prompt = @ab_test.prompt
      authorize prompt, :update?
      prompt.update!(current_version: @ab_test.winner_variant.prompt_version)
      redirect_to @ab_test, notice: "Winner promoted as the current prompt version."
    else
      redirect_to @ab_test, alert: "No winner has been determined yet."
    end
  rescue Pundit::NotAuthorizedError
    redirect_to @ab_test, alert: "You are not authorized to update this prompt."
  end

  private

  def set_ab_test
    @ab_test = policy_scope(AbTest).find(params[:id])
  end

  def ab_test_params
    params.require(:ab_test).permit(
      :name, :description, :prompt_id, :control_version_id,
      :min_samples_per_variant, :confidence_threshold,
      ab_test_variants_attributes: [ :id, :prompt_version_id, :is_control, :_destroy ]
    )
  end
end
