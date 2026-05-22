defmodule FeedReader.MixProject do
  use Mix.Project

  def project do
    [
      app: :feed_reader,
      version: "0.1.0",
      elixir: "~> 1.20.4",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [ignore_modules: [~r/^FeedReader\.TestSupport\./]],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7.19", only: :dev},
      {:date_time_parser, "~> 1.3.0"},
      {:ex_slop, "~> 0.4", only: :dev},
      {:html_sanitize_ex, "~> 1.5.5"},
      {:plug, "~> 1.0", only: :test},
      {:req, "~> 0.7.5"},
      {:saxy, "~> 1.6"},
      {:tongue, "~> 2.3.0"}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "test"
      ]
    ]
  end
end
