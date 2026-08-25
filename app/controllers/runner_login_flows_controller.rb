# frozen_string_literal: true

class RunnerLoginFlowsController < ApplicationController
  def new
    authorize RunnerCredential
    @runner_login_flows = RunnerLoginFlows::Registry.runner_keys.filter_map do |runner_key|
      flows = RunnerLoginFlows::Registry.flows_for(runner_key)
      next if flows.empty?

      [ runner_key, flows ]
    end.to_h
    @return_to_path = normalized_return_to(params[:return_to])
  end

  private

  def normalized_return_to(candidate)
    return if candidate.blank?

    parsed = URI.parse(candidate.to_s)
    return unless parsed.scheme.nil? && parsed.host.nil?
    return unless candidate.to_s.start_with?("/") && !candidate.to_s.start_with?("//")

    candidate.to_s
  rescue URI::InvalidURIError
    nil
  end
end
