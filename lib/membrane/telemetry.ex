defmodule Membrane.Telemetry do
  @moduledoc """
  Defines basic telemetry event types used by Membrane's Core.
  Membrane uses [Telemetry Package](https://hex.pm/packages/telemetry) for instrumentation and does not store or save any measurements by itself.

  It is user's responsibility to use some sort of metrics reporter
  that will be attached to `:telemetry` package to consume and process generated measurements.

  ## Instrumentation
  `Membrane.Telemetry` publishes functions that return described below event names.

  The following events are published by Membrane's Core with following measurement types and metadata:

    * `[:membrane, :metric, :value]` - used to report metrics, such as input buffer's size inside functions, incoming events and received caps.
        * Measurement: `t:metric_event_value_t/0`
        * Metadata: `%{}`

    * `[:membrane, :link, :new]` - to report new link connection being initialized in pipeline.
        * Measurement: `t:link_event_value_t/0`
        * Metadata: `%{}`

    * `[:membrane, :pipeline | :bin | :element, :init]` - to report pipeline/element/bin initialization
        * Measurement: `t:init_or_terminate_event_value_t/0`
        * Metadata: `%{}`

    * `[:membrane, :pipeline | :bin | :element, :terminate]` - to report pipeline/element/bin termination
        * Measurement: `t:init_or_terminate_event_value_t/0`
        * Metadata: `%{}`

  The measurements are reported only when application using Membrane Core specifies following in compile-time config file:

      config :membrane_core,
        enable_telemetry: true

  """

  @type event_name_t :: [atom(), ...]

  @typedoc """
  * component_path - element's or bin's path
  * metric - metric's name
  * value - metric's value
  """
  @type metric_event_value_t :: %{
          component_path: String.t(),
          metric: String.t(),
          value: integer()
        }

  @typedoc """
  * path - element's path
  """
  @type init_or_terminate_event_value_t :: %{
          path: Membrane.ComponentPath.path_t()
        }

  @typedoc """
  * parent_path - process path of link's parent
  * from - from element name
  * to - to element name
  * pad_from - from's pad name
  * pad_to - to's pad name
  """
  @type link_event_value_t :: %{
          parent_path: String.t(),
          from: String.t(),
          to: String.t(),
          pad_from: String.t(),
          pad_to: String.t()
        }
end
