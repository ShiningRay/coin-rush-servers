defmodule CoinRush.MixProject do
  use Mix.Project

  def project do
    [
      app: :coin_rush,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :cowboy],
      mod: {CoinRush.Application, []}
    ]
  end

  # Troupe：本地路径依赖（家庭仓布局）。 Cowboy：WS + 静态托管。 Jason：JSON 编解码。
  defp deps do
    [
      {:troupe, path: "../../troupe-elixir"},
      {:cowboy, "~> 2.10"},
      {:jason, "~> 1.4"}
    ]
  end
end
