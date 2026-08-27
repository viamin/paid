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
end
