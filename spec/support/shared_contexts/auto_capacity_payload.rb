# frozen_string_literal: true

RSpec.shared_context "with auto capacity payload" do
  let(:auto_capacity_payload) do
    {
      status: :healthy,
      sampled_at: 2.minutes.ago,
      docker_cpu_count: 8,
      docker_memory_bytes: 12.gigabytes,
      running_agent_count: 2,
      estimated_next_run_memory_bytes: 2.gigabytes,
      available_agent_memory_bytes: 6.gigabytes,
      control_plane_margin_bytes: 512.megabytes,
      effective_recommended_concurrency: 3,
      usage: {
        paid: { container_count: 2, cpu_percent: 15.0, memory_bytes: 2.gigabytes },
        agent: { container_count: 2, cpu_percent: 80.0, memory_bytes: 3.gigabytes },
        service: { container_count: 1, cpu_percent: 10.0, memory_bytes: 1.gigabyte },
        other: { container_count: 4, cpu_percent: 30.0, memory_bytes: 2.gigabytes }
      },
      warnings: [],
      manual_mode_summary: "Manual mode is enforcing a fixed limit of 4 concurrent runs today.",
      auto_mode_summary: "Auto preview would allow 3 concurrent runs because Docker currently has 6 GB available for agents and recent runs suggest 2 GB per run.",
      comparison_summary: "Auto preview is more conservative than the current manual limit."
    }
  end
end
