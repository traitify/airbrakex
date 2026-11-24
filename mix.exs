defmodule Airbrakex.Mixfile do
  use Mix.Project

  def project do
    [
      app: :airbrakex,
      version: "0.2.0",
      elixir: "~> 1.14",
      description: "Airbrake Elixir Notifier",
      package: package(),
      deps: deps(),
      dialyzer: dialyzer(),
      docs: [
        main: Airbrakex,
        source_url: "https://github.com/fazibear/airbrakex"
      ]
    ]
  end

  def package() do
    [
      maintainers: ["Michał Kalbarczyk"],
      licenses: ["MIT"],
      links: %{github: "https://github.com/fazibear/airbrakex"}
    ]
  end

  def application() do
    [
      extra_applications: [:logger],
      mod: {Airbrakex.Application, []}
    ]
  end

  defp deps() do
    [
      {:httpoison, "~> 2.2"},
      {:jason, "~> 1.1"},
      {:bypass, "~> 2.1", only: :test},
      # cowlib >= 2.20 needs OTP 27; services run OTP 26.
      {:cowboy, "~> 2.18.0", only: :test},
      {:cowlib, "~> 2.19.0", only: :test, override: true},
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:credo, "~> 1.0.0", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0.0-rc.4", only: :dev, runtime: false}
    ]
  end

  defp dialyzer do
    [
      plt_add_deps: :apps_direct,
      plt_add_apps: [:hackney, :logger, :mix],
      flags: [:error_handling, :race_conditions, :unmatched_returns]
    ]
  end
end
