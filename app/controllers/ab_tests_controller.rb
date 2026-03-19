# frozen_string_literal: true

class AbTestsController < ApplicationController
  before_action :set_prompt
  before_action :set_ab_test, only: [ :show, :start, :cancel, :promote ]
  skip_after_action :verify_authorized, only: :index

  def index
    @ab_tests = policy_scope(AbTest).where(prompt: @prompt)
                                    .includes(:control_version, :winner_variant, :ab_test_variants)
                                    .order(created_at: :desc)
  end

  def show
    authorize @ab_test
    @variants = @ab_test.ab_test_variants.includes(:prompt_version).order(is_control: :desc)
    @analysis = analyze_if_available(@variants)
  end

  def new
    @ab_test = @prompt.ab_tests.build
    authorize @ab_test
    @versions = available_versions
  end

  def create
    authorize @prompt.ab_tests.build, :create?

    create_options = {
      prompt: @prompt,
      name: ab_test_params[:name],
      description: ab_test_params[:description],
      variant_version_ids: selected_variant_ids
    }
    # Use strict parsing so invalid input (e.g. "abc") raises an error
    # instead of silently coercing to 0/0.0 via to_i/to_f.
    create_options[:min_samples_per_variant] = Integer(ab_test_params[:min_samples_per_variant]) if ab_test_params[:min_samples_per_variant].present?
    create_options[:confidence_threshold] = Float(ab_test_params[:confidence_threshold]) if ab_test_params[:confidence_threshold].present?

    ab_test = AbTests::Create.call(**create_options)

    redirect_to prompt_ab_test_path(@prompt, ab_test), notice: "A/B test was successfully created."
  rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
    @ab_test = @prompt.ab_tests.build(
      name: ab_test_params[:name],
      description: ab_test_params[:description],
      min_samples_per_variant: ab_test_params[:min_samples_per_variant],
      confidence_threshold: ab_test_params[:confidence_threshold]
    )
    message = e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.join(", ") : e.message
    @ab_test.errors.add(:base, message)
    @selected_variant_ids = selected_variant_ids
    @versions = available_versions
    render :new, status: :unprocessable_content
  end

  def start
    authorize @ab_test, :update?
    @ab_test.start!
    redirect_to prompt_ab_test_path(@prompt, @ab_test), notice: "A/B test has been started."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to prompt_ab_test_path(@prompt, @ab_test), alert: e.record.errors.full_messages.join(", ")
  end

  def cancel
    authorize @ab_test, :update?
    @ab_test.cancel!
    redirect_to prompt_ab_test_path(@prompt, @ab_test), notice: "A/B test has been cancelled."
  rescue ActiveRecord::RecordInvalid => e
    redirect_to prompt_ab_test_path(@prompt, @ab_test), alert: e.record.errors.full_messages.join(", ")
  end

  def promote
    authorize @ab_test, :update?
    AbTests::PromoteWinner.call(ab_test: @ab_test)
    redirect_to prompt_ab_test_path(@prompt, @ab_test),
                notice: "Winner promoted! v#{@ab_test.winner_variant.prompt_version.version} is now the current version."
  rescue ArgumentError => e
    redirect_to prompt_ab_test_path(@prompt, @ab_test), alert: e.message
  end

  private

  def set_prompt
    @prompt = policy_scope(Prompt).find(params[:prompt_id])
  end

  def set_ab_test
    @ab_test = @prompt.ab_tests.find(params[:id])
  end

  def ab_test_params
    params.require(:ab_test).permit(:name, :description, :min_samples_per_variant, :confidence_threshold,
                                    variant_version_ids: [])
  end

  def selected_variant_ids
    Array(ab_test_params[:variant_version_ids]).reject(&:blank?).map(&:to_i)
  end

  def available_versions
    @prompt.prompt_versions.order(version: :desc)
  end

  def analyze_if_available(variants)
    return unless variants.any? { |v| v.sample_count > 0 }

    # Completed tests always show analysis (final result).
    # Running tests only compute analysis once sufficient samples exist to avoid
    # expensive per-request score aggregation while data is still sparse.
    return unless @ab_test.completed? || (@ab_test.running? && @ab_test.sufficient_samples?)

    # persist: false returns the last cached result (even if slightly stale)
    # instead of recomputing — keeps GET requests read-only and avoids expensive
    # score aggregation between write-path analysis intervals.
    @ab_test.cached_or_compute_analysis(persist: false)
  end
end
