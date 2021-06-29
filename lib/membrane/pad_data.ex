defmodule Membrane.Pad.Data do
  @moduledoc """
  Struct describing current pad state.

  The public fields are:
    - `:accepted_caps` - specification of possible caps that are accepted on the pad.
      See `Membrane.Caps.Matcher` for more information. This field only applies to elements' pads.
    - `:availability` - see `Membrane.Pad.availability_t`
    - `:caps` - the most recent `Membrane.Caps` that have been sent (output) or received (input)
      on the pad. May be `nil` if not yet set. This field only applies to elements' pads.
    - `:demand` - current demand requested on the pad working in pull mode. This field only applies to elements' pads.
    - `:direction` - see `Membrane.Pad.direction_t`
    - `:end_of_stream?` - flag determining whether the stream processing via the pad has been finished
    - `:mode` - see `Membrane.Pad.mode_t`. This field only applies to elements' pads.
    - `:name` - see `Membrane.Pad.name_t`. Do not mistake with `:ref`
    - `:options` - options passed in `Membrane.ParentSpec` when linking pad
    - `:ref` - see `Membrane.Pad.ref_t`
    - `:start_of_stream?` - flag determining whether the stream processing via the pad has been started

  Other fields in the struct ARE NOT PART OF THE PUBLIC API and should not be
  accessed or relied on.
  """
  use Bunch.Access

  alias Membrane.Buffer.Metric
  alias Membrane.Core.InputBuffer
  alias Membrane.{Caps, Event, Pad}

  @type t :: %__MODULE__{
          accepted_caps: Caps.Matcher.caps_specs_t(),
          availability: Pad.availability_t(),
          direction: Pad.direction_t(),
          mode: Pad.mode_t(),
          name: Pad.name_t(),
          ref: Pad.ref_t(),
          demand_unit: Metric.unit_t() | nil,
          other_demand_unit: Metric.unit_t() | nil,
          pid: pid,
          other_ref: Pad.ref_t(),
          caps: Caps.t() | nil,
          start_of_stream?: boolean(),
          end_of_stream?: boolean(),
          sticky_messages: [Event.t()],
          input_buf: InputBuffer.t() | nil,
          demand: integer() | nil,
          options: %{optional(atom) => any}
        }

  defstruct accepted_caps: nil,
            availability: nil,
            direction: nil,
            mode: nil,
            name: nil,
            ref: nil,
            demand_unit: nil,
            other_demand_unit: nil,
            pid: nil,
            other_ref: nil,
            caps: nil,
            start_of_stream?: nil,
            end_of_stream?: nil,
            sticky_messages: nil,
            input_buf: nil,
            demand: nil,
            options: %{},
            demand_pads: [],
            demand_inputs: nil,
            demand_mode: nil
end
