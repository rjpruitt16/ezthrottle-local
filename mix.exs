defmodule EzthrottleLocal.MixProject do
  use Mix.Project

  def project do
    [
      app: :ezthrottle_local,
      version: "0.5.0",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {EzthrottleLocal.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :crypto],
      # :mnesia goes in included_applications, not extra_applications:
      # extra_applications get auto-started by OTP *before*
      # EzthrottleLocal.Application.start/2 runs, which would start Mnesia
      # with its default (RAM-only) directory before our code ever gets to
      # configure :dir and call create_schema/start explicitly.
      # included_applications still bundles Mnesia's code into a release
      # without OTP auto-starting it — we start it ourselves in
      # IdempotentStore.ensure_schema!/0, after configuring where it writes.
      included_applications: [:mnesia]
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
      {:phoenix, "~> 1.7.18"},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.1.1"},
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
      setup: ["deps.get"]
    ]
  end
end
