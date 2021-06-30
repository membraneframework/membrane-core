defmodule Membrane.Mixfile do
  use Mix.Project

  @version "0.7.0"
  @source_ref "v#{@version}"

  def project do
    [
      app: :membrane_core,
      version: @version,
      elixir: "~> 1.10",
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "Membrane Multimedia Framework (Core)",
      dialyzer: [
        flags: [:error_handling]
      ],
      package: package(),
      name: "Membrane Core",
      source_url: link(),
      docs: docs(),
      aliases: ["test.all": "do espec, test"],
      preferred_cli_env: [
        espec: :test,
        "test.all": :test,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ],
      test_coverage: [tool: ExCoveralls, test_task: "test.all"],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [], mod: {Membrane, []}]
  end

  defp elixirc_paths(:test), do: ["lib", "spec/support", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp link do
    "https://github.com/membraneframework/membrane-core"
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CONTRIBUTING.md", LICENSE: [title: "License"]],
      source_ref: @source_ref,
      nest_modules_by_prefix: [
        Membrane.Bin,
        Membrane.Pipeline,
        Membrane.Element,
        Membrane.Element.CallbackContext,
        Membrane.Pipeline.CallbackContext,
        Membrane.Bin.CallbackContext,
        Membrane.Payload,
        Membrane.Buffer,
        Membrane.Caps,
        Membrane.Event,
        Membrane.EventProtocol,
        Membrane.Testing
      ],
      groups_for_modules: [
        Pipeline: [~r/^Membrane\.Pipeline($|\.)/],
        Bin: [~r/^Membrane\.Bin($|\.)/],
        Element: [
          ~r/^Membrane\.Filter($|\.)/,
          ~r/^Membrane\.Sink($|\.)/,
          ~r/^Membrane\.Source($|\.)/,
          ~r/^Membrane\.Element($|\.)/,
          ~r/^Membrane\.Core\.InputBuffer($|\.)/
        ],
        Parent: [~r/^Membrane\.(Parent|ParentSpec)($|\.)/],
        Child: [~r/^Membrane\.(Child|ChildEntry)($|\.)/],
        Communication: [
          ~r/^Membrane\.(Buffer|Payload|Caps|Event|EventProtocol|Notification|Pad|KeyframeRequestEvent|RemoteStream)($|\.)/
        ],
        "Fault tolerance": [~r/^Membrane\.(CrashGroup)($|\.)/],
        Logging: [~r/^Membrane\.Logger($|\.)/],
        Testing: [~r/^Membrane\.Testing($|\.)/],
        Utils: [
          ~r/^Membrane\.Clock($|\.)/,
          ~r/^Membrane\.Sync($|\.)/,
          ~r/^Membrane\.Time($|\.)/,
          ~r/^Membrane\.PlaybackState($|\.)/,
          ~r/^Membrane\.Telemetry($|\.)/,
          ~r/^Membrane\.ComponentPath($|\.)/
        ],
        Errors: [~r/Error$/],
        Deprecated: [~r/^Membrane\.Log($|\.)/]
      ]
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache 2.0"],
      links: %{
        "GitHub" => link(),
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.21", only: :dev, runtime: false},
      {:dialyxir, "~> 1.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.4", only: :dev, runtime: false},
      {:espec, "~> 1.8.3", only: :test},
      {:excoveralls, "~> 0.11", only: :test},
      {:qex, "~> 0.3"},
      {:telemetry, "~> 0.4"},
      {:bunch, "~> 1.3"},
      {:ratio, "~> 2.0"}
    ]
  end
end
