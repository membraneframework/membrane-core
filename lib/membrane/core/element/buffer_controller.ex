defmodule Membrane.Core.Element.BufferController do
  @moduledoc false

  # Module handling buffers incoming through input pads.

  use Bunch

  alias Membrane.{Buffer, Pad}
  alias Membrane.Core.{CallbackHandler, InputBuffer, Telemetry}
  alias Membrane.Core.Child.PadModel
  alias Membrane.Core.Element.{ActionHandler, DemandController, DemandHandler, State}
  alias Membrane.Element.CallbackContext

  require Membrane.Core.Child.PadModel

  @doc """
  Handles incoming buffer: either stores it in InputBuffer, or executes element's
  callback. Also calls `Membrane.Core.Element.DemandHandler.check_and_handle_demands/2`
  to check if there are any unsupplied demands.
  """
  @spec handle_buffer(Pad.ref_t(), [Buffer.t()] | Buffer.t(), State.t()) :: State.stateful_try_t()
  def handle_buffer(pad_ref, buffers, state) do
    PadModel.assert_data!(state, pad_ref, %{direction: :input})

    case PadModel.get_data!(state, pad_ref) do
      %{mode: :pull, demand_pads: []} -> handle_buffer_pull(pad_ref, buffers, state)
      %{mode: :pull} -> handle_buffer_auto_pull(pad_ref, buffers, state)
      %{mode: :push} -> exec_buffer_handler(pad_ref, buffers, state)
    end
  end

  @doc """
  Executes `handle_process` or `handle_write_list` callback.
  """
  @spec exec_buffer_handler(
          Pad.ref_t(),
          [Buffer.t()] | Buffer.t(),
          State.t()
        ) :: State.stateful_try_t()
  def exec_buffer_handler(pad_ref, buffers, %State{type: :filter} = state) do
    require CallbackContext.Process
    Telemetry.report_metric("buffer", 1, inspect(pad_ref))

    CallbackHandler.exec_and_handle_callback(
      :handle_process_list,
      ActionHandler,
      %{context: &CallbackContext.Process.from_state/1},
      [pad_ref, buffers],
      state
    )
  end

  def exec_buffer_handler(pad_ref, buffers, %State{type: :sink} = state) do
    require CallbackContext.Write

    CallbackHandler.exec_and_handle_callback(
      :handle_write_list,
      ActionHandler,
      %{context: &CallbackContext.Write.from_state/1},
      [pad_ref, buffers],
      state
    )
  end

  @spec handle_buffer_pull(Pad.ref_t(), [Buffer.t()] | Buffer.t(), State.t()) ::
          State.stateful_try_t()
  defp handle_buffer_pull(pad_ref, buffers, state) do
    with {:ok, old_input_buf} <- PadModel.get_data(state, pad_ref, :input_buf) do
      input_buf = InputBuffer.store(old_input_buf, buffers)
      state = PadModel.set_data!(state, pad_ref, :input_buf, input_buf)

      if old_input_buf |> InputBuffer.empty?() do
        DemandHandler.supply_demand(pad_ref, state)
      else
        {:ok, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp handle_buffer_auto_pull(pad_ref, buffers, state) do
    state = PadModel.update_data!(state, pad_ref, :demand, &(&1 - length(buffers)))
    state = DemandController.check_auto_demand(pad_ref, state)
    exec_buffer_handler(pad_ref, buffers, state)
  end
end
