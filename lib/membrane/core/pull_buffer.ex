defmodule Membrane.Core.PullBuffer do
  @moduledoc """
  Buffer that is attached to the `:input` pad when working in a `:pull` mode.

  It stores `Membrane.Buffer`, `Membrane.Event` and `Membrane.Caps` structs and
  prevents the situation where the data in a stream contains the discontinuities.
  It also guarantees that element won't be flooded with the incoming data.
  """
  alias Membrane.Buffer
  alias Membrane.Core.Message
  require Message
  use Bunch
  use Membrane.Log, tags: :core

  @qe Qex

  @non_buf_types [:event, :caps]

  @type t :: %__MODULE__{
          name: Membrane.Element.name_t(),
          demand_pid: pid(),
          input_ref: Membrane.Element.Pad.ref_t(),
          q: @qe.t(),
          preferred_size: pos_integer(),
          current_size: non_neg_integer(),
          demand: non_neg_integer(),
          min_demand: pos_integer(),
          metric: module(),
          toilet: boolean()
        }

  defstruct name: :pull_buffer,
            demand_pid: nil,
            input_ref: nil,
            q: nil,
            preferred_size: 100,
            current_size: 0,
            demand: nil,
            min_demand: nil,
            metric: nil,
            toilet: false

  @typedoc """
  Properties that can be passed when creating new PullBuffer
  """
  @type prop_t ::
          {:preferred_size, pos_integer()}
          | {:min_demand, pos_integer()}
          | {:toilet, boolean()}

  @type props_t :: [prop_t()]

  @spec new(
          Membrane.Element.name_t(),
          demand_pid :: pid,
          Membrane.Element.Pad.ref_t(),
          Membrane.Buffer.Metric.unit_t(),
          props_t
        ) :: t()
  def new(name, demand_pid, input_ref, demand_unit, props) do
    metric = Buffer.Metric.from_unit(demand_unit)
    preferred_size = props[:preferred_size] || metric.pullbuffer_preferred_size
    min_demand = props[:min_demand] || preferred_size |> div(4)
    default_toilet = %{warn: preferred_size * 2, fail: preferred_size * 4}

    toilet =
      case props[:toilet] do
        true -> default_toilet
        t when t in [nil, false] -> false
        t -> default_toilet |> Map.merge(t |> Map.new())
      end

    %__MODULE__{
      name: name,
      q: @qe.new,
      demand_pid: demand_pid,
      input_ref: input_ref,
      preferred_size: preferred_size,
      min_demand: min_demand,
      demand: preferred_size,
      metric: metric,
      toilet: toilet
    }
    |> fill()
  end

  @spec fill(t()) :: t()
  defp fill(%__MODULE__{} = pb), do: handle_demand(pb, 0)

  @spec store(t(), atom(), any()) :: {:ok, t()} | {:error, any()}
  def store(pb, type \\ :buffers, v)

  def store(
        %__MODULE__{current_size: size, preferred_size: pref_size, toilet: false} = pb,
        :buffers,
        v
      )
      when is_list(v) do
    if size >= pref_size do
      debug("""
      PullBuffer #{inspect(pb.name)}: received buffers from input #{inspect(pb.input_ref)},
      despite not requesting them. It is probably caused by overestimating demand
      by previous element.
      """)
    end

    {:ok, do_store_buffers(pb, v)}
  end

  def store(%__MODULE__{toilet: %{warn: warn_lvl, fail: fail_lvl}} = pb, :buffers, v)
      when is_list(v) do
    %__MODULE__{current_size: size} = pb = do_store_buffers(pb, v)

    if size >= warn_lvl do
      above_level =
        if size < fail_lvl do
          "warn level"
        else
          "fail_level"
        end

      warn([
        """
        PullBuffer #{inspect(pb.name)} (toilet): received #{inspect(size)} buffers,
        which is above #{above_level}, from input #{inspect(pb.input_ref)} that works in push mode.
        To have control over amount of buffers being produced, consider using push mode.
        If this is a normal situation, increase toilet warn/fail level.
        Buffers: \
        """,
        Buffer.print(v),
        """

        PullBuffer #{inspect(pb)}
        """
      ])
    end

    if size >= fail_lvl do
      warn_error(
        "PullBuffer #{inspect(pb.name)} (toilet): failing: too many buffers",
        {:pull_buffer, toilet: :too_many_buffers}
      )
    else
      {:ok, pb}
    end
  end

  def store(pb, :buffer, v), do: store(pb, :buffers, [v])

  def store(%__MODULE__{q: q} = pb, type, v) when type in @non_buf_types do
    report("Storing #{type}", pb)
    {:ok, %__MODULE__{pb | q: q |> @qe.push({:non_buffer, type, v})}}
  end

  defp do_store_buffers(%__MODULE__{q: q, current_size: size, metric: metric} = pb, v) do
    buf_cnt = v |> metric.buffers_size
    report("Storing #{inspect(buf_cnt)} buffers", pb)

    %__MODULE__{
      pb
      | q: q |> @qe.push({:buffers, v, buf_cnt}),
        current_size: size + buf_cnt
    }
  end

  def take(%__MODULE__{current_size: size} = pb, count) when count >= 0 do
    report("Taking #{inspect(count)} buffers", pb)
    {out, %__MODULE__{current_size: new_size} = pb} = do_take(pb, count)
    pb = pb |> handle_demand(size - new_size)
    {{:ok, out}, pb}
  end

  defp do_take(%__MODULE__{q: q, current_size: size, metric: metric} = pb, count) do
    {out, nq} = q |> q_pop(count, metric)
    {out, %__MODULE__{pb | q: nq, current_size: max(0, size - count)}}
  end

  defp q_pop(q, count, metric, acc \\ [])

  defp q_pop(q, count, metric, acc) when count > 0 do
    q
    |> @qe.pop
    |> case do
      {{:value, {:buffers, b, buf_cnt}}, nq} when count >= buf_cnt ->
        q_pop(nq, count - buf_cnt, metric, [{:buffers, b, buf_cnt} | acc])

      {{:value, {:buffers, b, buf_cnt}}, nq} when count < buf_cnt ->
        {b, back} = b |> metric.split_buffers(count)
        nq = nq |> @qe.push_front({:buffers, back, buf_cnt - count})
        {{:value, [{:buffers, b, count} | acc] |> Enum.reverse()}, nq}

      {:empty, nq} ->
        {{:empty, acc |> Enum.reverse()}, nq}

      {{:value, {:non_buffer, type, e}}, nq} ->
        q_pop(nq, count, metric, [{type, e} | acc])
    end
  end

  defp q_pop(q, 0, metric, acc) do
    q
    |> @qe.pop
    |> case do
      {{:value, {:non_buffer, type, e}}, nq} -> q_pop(nq, 0, metric, [{type, e} | acc])
      _ -> {{:value, acc |> Enum.reverse()}, q}
    end
  end

  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{current_size: size}), do: size == 0

  defp handle_demand(
         %__MODULE__{
           toilet: false,
           demand_pid: demand_pid,
           input_ref: input_ref,
           current_size: size,
           preferred_size: pref_size,
           demand: demand,
           min_demand: min_demand
         } = pb,
         new_demand
       )
       when size < pref_size and demand + new_demand > 0 do
    to_demand = max(demand + new_demand, min_demand)

    report(
      """
      Sending demand of size #{inspect(to_demand)}
      to input #{inspect(pb.input_ref)}
      """,
      pb
    )

    Message.send(demand_pid, :demand, [to_demand, input_ref])
    %__MODULE__{pb | demand: demand + new_demand - to_demand}
  end

  defp handle_demand(%__MODULE__{toilet: false, demand: demand} = pb, new_demand),
    do: %__MODULE__{pb | demand: demand + new_demand}

  defp handle_demand(%__MODULE__{toilet: toilet} = pb, _new_demand) when toilet != false do
    pb
  end

  defp report(msg, %__MODULE__{
         name: name,
         current_size: size,
         preferred_size: pref_size,
         toilet: toilet
       }) do
    name_str =
      if toilet do
        "#{inspect(name)} (toilet)"
      else
        inspect(name)
      end

    debug([
      "PullBuffer #{name_str}: ",
      msg,
      "\n",
      "PullBuffer size: #{inspect(size)}, ",
      if toilet do
        "toilet limits: #{inspect(toilet)}"
      else
        "preferred size: #{inspect(pref_size)}"
      end
    ])
  end
end
