defmodule Membrane.Core.Element.CapsController do
  @moduledoc false

  # Module handling caps received on input pads.

  use Bunch

  alias Membrane.{Caps, Pad}
  alias Membrane.Core.{CallbackHandler, InputBuffer, Telemetry}
  alias Membrane.Core.Child.PadModel
  alias Membrane.Core.Element.{ActionHandler, State}
  alias Membrane.Element.CallbackContext

  require Membrane.Core.Child.PadModel
  require Membrane.Logger

  @doc """
  Handles incoming caps: either stores them in InputBuffer, or executes element callback.
  """
  @spec handle_caps(Pad.ref_t(), Caps.t(), State.t()) :: State.stateful_try_t()
  def handle_caps(pad_ref, caps, state) do
    Telemetry.report_metric(:caps, 1, inspect(pad_ref))

    PadModel.assert_data!(state, pad_ref, %{direction: :input})
    data = PadModel.get_data!(state, pad_ref)

    if data.mode == :pull and not (data.input_buf |> InputBuffer.empty?()) do
      PadModel.update_data(state, pad_ref, :input_buf, &{:ok, InputBuffer.store(&1, :caps, caps)})
    else
      exec_handle_caps(pad_ref, caps, state)
    end
  end

  @spec exec_handle_caps(Pad.ref_t(), Caps.t(), params :: map, State.t()) ::
          State.stateful_try_t()
  def exec_handle_caps(pad_ref, caps, params \\ %{}, state) do
    require CallbackContext.Caps
    %{accepted_caps: accepted_caps} = PadModel.get_data!(state, pad_ref)
    context = &CallbackContext.Caps.from_state(&1, pad: pad_ref)

    withl match: true <- Caps.Matcher.match?(accepted_caps, caps),
          callback:
            {:ok, state} <-
              CallbackHandler.exec_and_handle_callback(
                :handle_caps,
                ActionHandler,
                %{context: context} |> Map.merge(params),
                [pad_ref, caps],
                state
              ) do
      {:ok, PadModel.set_data!(state, pad_ref, :caps, caps)}
    else
      match: false ->
        Membrane.Logger.error("""
        Received caps: #{inspect(caps)} that are not specified in def_input_pad
        for pad #{inspect(pad_ref)}. Specs of accepted caps are:
        #{inspect(accepted_caps, pretty: true)}
        """)

        {{:error, :invalid_caps}, state}

      callback: {{:error, reason}, state} ->
        {{:error, reason}, state}
    end
  end
end
