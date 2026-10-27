defmodule FeedReader.MixProject do
  use Mix.Project

  def project do
    [
      app: :feed_reader,
      name: "FeedReader",
      version: "0.1.0",
      description: description(),
      elixir: "~> 1.20.4",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [ignore_modules: [~r/^FeedReader\.TestSupport\./]],
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp package,
    do: %{
      licenses: ["Apache-2.0"],
      links: %{"git" => "https://git.codeup.net/mmacia/feed_reader"}
    }

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/usage.md",
        "guides/streaming.md",
        "guides/resource-limits.md",
        "guides/results.md",
        "guides/customization.md",
        "guides/xml-recovery.md"
      ],
      groups_for_extras: [
        Guides: [
          "guides/usage.md",
          "guides/streaming.md",
          "guides/resource-limits.md",
          "guides/results.md",
          "guides/customization.md",
          "guides/xml-recovery.md"
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:credo, "~> 1.7.19", only: :dev},
      {:date_time_parser, "~> 1.3.0"},
      {:ex_doc, "~> 0.40.0", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: :dev},
      {:html_sanitize_ex, "~> 1.5.5"},
      {:plug, "~> 1.0", only: :test},
      {:req, "~> 0.7.5"},
      {:saxy, "~> 1.6"},
      {:tongue, "~> 2.3.0"}
    ]
  end

  defp description,
    do: """
    FeedReader is an Elixir library for fetching and parsing RSS, Atom, and RDF feeds. It supports local files, binaries, streams, and remote URLs.
    """

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
