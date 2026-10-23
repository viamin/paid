# frozen_string_literal: true

module AgentRunFilterOptions
  private

  def available_filter_options(scope)
    values = scope.distinct.pluck(:status, :agent_type, :goal)

    {
      status: values.filter_map(&:first).uniq,
      agent_type: values.filter_map { |row| row[1] }.uniq,
      goal: values.filter_map { |row| row[2] }.uniq
    }
  end
end
