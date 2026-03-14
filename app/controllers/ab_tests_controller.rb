# frozen_string_literal: true

class AbTestsController < ApplicationController
  before_action :set_ab_test, only: [ :show, :edit, :update, :destroy, :start, :pause, :complete, :promote_winner ]
  skip_after_action :verify_authorized, only: :index

  def index
    base_scope = policy_scope(AbTest).includes(:prompt, :variants)
    @q = base_scope.ransack(params[:q])
    @q.sorts = "created_at desc" if @q.sorts.empty?
    @pagy, @ab_tests = pagy(@q.result)
  end

  def show
    authorize @ab_test
    @analysis = AbTests::Analyze.call(ab_test: @ab_test) if @ab_test.running? || @ab_test.completed?
  end

  def new
    @ab_test = current_account.ab_tests.build
    authorize @ab_test
    @prompts = policy_scope(Prompt).active.includes(:current_version).order(:name)
  end

  def create
    @ab_test = current_account.ab_tests.build(ab_test_params)
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
  rescue RuntimeError => e
    redirect_to @ab_test, alert: e.message
  end

  def pause
    authorize @ab_test, :update?
    @ab_test.pause!
    redirect_to @ab_test, notice: "A/B test has been paused."
  rescue RuntimeError => e
    redirect_to @ab_test, alert: e.message
  end

  def complete
    authorize @ab_test, :update?
    @ab_test.complete!
    redirect_to @ab_test, notice: "A/B test has been completed."
  rescue RuntimeError => e
    redirect_to @ab_test, alert: e.message
  end

  def promote_winner
    authorize @ab_test, :update?

    if @ab_test.winner_variant.present?
      prompt = @ab_test.prompt
      prompt.update!(current_version: @ab_test.winner_variant.prompt_version)
      redirect_to @ab_test, notice: "Winner promoted as the current prompt version."
    else
      redirect_to @ab_test, alert: "No winner has been determined yet."
    end
  end

  private

  def set_ab_test
    @ab_test = policy_scope(AbTest).find(params[:id])
  end

  def ab_test_params
    params.require(:ab_test).permit(:name, :description, :prompt_id, :traffic_percentage, :min_sample_size)
  end
end
