# frozen_string_literal: true

defmodule ColorMatching.MixProject do
  use Mix.Project

  def project do
    [
      app: :color_matching,
      version: "0.1.0",
      elixir: "~> 1.17"
    ]
  end

  def application do
    [
      mod: {ColorMatching.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp deps do
    [
      {:phoenix, "~> 1.7.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:phoenix_live_view, "~> 1.0.0-rc.6"},
      {:postgrex, ">= 0.0.0"},
      {:redix, ">= 0.0.0"}
    ]
  end
end
