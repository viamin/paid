# frozen_string_literal: true

module RunnersHelper
  def runner_usage_stats_for(runner)
    return unless @usage_stats

    stats = @usage_stats[runner.runner_key]
    stats ||= @usage_stats[runner.routing_key]
    stats
  end

  def format_token_count(count)
    if count >= 1_000_000
      "#{(count / 1_000_000.0).round(1)}M"
    elsif count >= 1_000
      "#{(count / 1_000.0).round(1)}k"
    else
      count.to_s
    end
  end
end
