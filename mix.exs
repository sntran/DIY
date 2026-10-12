defmodule DIY.MixProject do
  use Mix.Project

  def project do
    [
      app: :diy,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      # mix test --cover: each line of the app must run. The wait of
      # DIYWeb.ConnCase (a help of the tests) runs only when an answer is
      # slow, so it is not in the count.
      test_coverage: [summary: [threshold: 100], ignore_modules: [DIYWeb.ConnCase]],
      # RELEASE_ERTS=false: a release with no ERTS, for beam.com (see
      # scripts/edge-com.sh).
      releases: [diy: [include_erts: System.get_env("RELEASE_ERTS") != "false"]]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {DIY.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.15"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      # The tests of LiveView. beam.com has its NIF in WebAssembly, only for
      # this version (docs/NIFS.md of BEAM.com).
      {:lazy_html, "0.1.13", only: :test},
      {:stream_data, "~> 1.4", only: [:dev, :test]},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
       app: false,
       compile: false,
       depth: 1},
      {:jason, "~> 1.2"},
      # The texts of the pages in English, Spanish and Vietnamese
      # (`DIY.Gettext`).
      {:gettext, "~> 1.0"},
      # The HTTP client of the weather and of Power to Choose. On Cloudflare,
      # the VM sends its HTTP through fetch() of the Worker. Do not add
      # castore: the VM trusts only :public_key.cacerts_get/0.
      {:req, "~> 0.5"},
      {:bandit, "~> 1.5"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind diy", "esbuild diy", "esbuild pdf"],
      "assets.deploy": [
        "tailwind diy --minify",
        "esbuild diy --minify",
        "esbuild pdf --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        # The keys of the texts (priv/gettext/default.pot) follow the code.
        "gettext.extract --check-up-to-date",
        "test --cover",
        # The tests of the JavaScript of the page (test/js/), with Node.js.
        "cmd npm test --silent"
      ]
    ]
  end
end
