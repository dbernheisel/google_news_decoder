defmodule GoogleNewsDecoder.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/dbernheisel/google_news_decoder"

  def project do
    [
      app: :google_news_decoder,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "GoogleNewsDecoder",
      description:
        "Decode Google News redirect URLs to their original source URLs. Zero dependencies.",
      source_url: @source_url,
      homepage_url: @source_url,
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key]
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:mimic, "~> 1.11", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "GoogleNewsDecoder",
      source_ref: "v#{@version}"
    ]
  end
end
