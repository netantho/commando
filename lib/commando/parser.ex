defmodule Commando.Parser do
  @moduledoc false

  alias Commando.Cmd
  alias Commando.Util

  def parse(args, spec, config) do
    try do
      {:ok, do_parse(args, spec, config)}
    catch
      :throw, {:parse_error, :missing_cmd=reason} ->
        if config[:exec_help] and (has_help_cmd(spec) or has_help_opt(spec)) do
          IO.puts Commando.help(spec)
          halt(config, 2)
        else
          process_error(reason, config)
        end

      :throw, {:parse_error, [first|_]} ->
        process_error(first, config)

      :throw, {:parse_error, reason} ->
        process_error(reason, config)
    end
  end

  defp process_error(reason, config) do
    case config[:format_errors] do
      :return -> {:error, reason}
      :raise -> raise RuntimeError, message: Util.format_error(reason)
      :report ->
        IO.puts Util.format_error(reason)
        halt(config, 1)
    end
  end

  ###

  defp internal_parse_head(args, opts) do
    case OptionParser.parse_head(args, opts) do
      {opts, ["--"|args], []} -> {opts, args, []}
      other -> other
    end
  end

  defp internal_parse(args, opts) do
    case OptionParser.parse(args, opts) do
      {opts, ["--"|args], []} -> {opts, args, []}
      other -> other
    end
  end

  defp do_parse(args, spec, config) do
    opts = spec_to_parser_opts(spec)
    commands = spec[:commands]
    {opts, args, invalid} = if is_list(commands) and commands != [] do
      internal_parse_head(args, opts)
    else
      internal_parse(args, opts)
    end

    opts = process_opts(opts, invalid, spec, config)
    args = process_args(args, spec)

    topcmd = %Commando.Cmd{
      name: spec[:name],
      options: opts,
      arguments: args,
    }

    if spec[:commands] do
      case parse_cmd(args, spec, config) do
        {:ok, cmd} ->
          topcmd = %Cmd{topcmd | subcmd: cmd, arguments: nil}
          cmd_spec = Enum.find(spec[:commands], fn cmd_spec ->
            cmd_spec.name == cmd.name
          end)
          execute_cmd_if_needed(topcmd, cmd_spec, spec, config)

        {:error, reason} -> throw parse_error(reason)
      end
    end

    topcmd
  end

  defp check_opt_error(opts, f) do
    case f.(opts) do
      {opts, []} -> opts
      {_, bad_opts} -> throw parse_error(bad_opts)
    end
  end

  ###

  defp spec_to_parser_opts(%{options: options}) do
    {s, a} = Enum.reduce(options, {[], []}, fn opt, {switches, aliases} ->
      opt_name = opt_name_to_atom(opt)
      kind = []

      if valtype=opt[:valtype], do: kind = [valtype|kind]

      case opt[:multival] do
        :overwrite ->
          nil
        keep when keep in [:keep, :accumulate, :error] ->
          kind = [:keep|kind]
      end
      if kind != [], do: switches = [{opt_name, kind}|switches]

      if short=opt[:short] do
        aliases = [{binary_to_atom(short), opt_name}|aliases]
      end

      {switches, aliases}
    end)
    [switches: s, aliases: a]
  end

  ###

  defp process_opts(opts, [], spec, config) do
    opts
    |> check_opt_error(&filter_undefined_opts(&1, spec))
    |> check_opt_error(&validate_opts(&1, spec))
    |> postprocess_opts(spec)
    |> execute_opts_if_needed(spec, config)
  end

  defp process_opts(_, invalid, spec, _) do
    invalid = process_invalid_opts(invalid, spec)
    throw parse_error(invalid)
  end


  defp process_args(args, spec) do
    case validate_args(args, spec) do
      {:ok, args} -> args
      {:error, reason} ->
        throw parse_error(reason)
    end
  end

  ###

  defp process_invalid_opts(invalid, spec) do
    option_set = Enum.reduce(spec[:options], %{}, fn opt, set ->
      if short=opt[:short], do:
        set = Map.put(set, binary_to_atom(short), true)
      if name=opt[:name], do:
        set = Map.put(set, binary_to_atom(name), true)
      set
    end)

    Enum.map(invalid, fn {name, val} ->
      cond do
        !option_set[name] ->
          {:bad_opt, name}

        spec[:valtype] != :boolean and val in [false, true] ->
          {:missing_opt_arg, name}

        true ->
          {:bad_opt_value, {name, val}}
      end
    end)
  end

  defp filter_undefined_opts(opts, spec) do
    # Check if there are any extraneous switches
    option_set = Enum.map(spec[:options], fn opt ->
      {opt_name_to_atom(opt), true}
    end) |> Enum.into(%{})

    Enum.reduce(opts, {[], []}, fn {name, _}=opt, {good, bad} ->
      if !option_set[name] do
        bad = bad ++ [{:bad_opt, name}]
      else
        good = good ++ [opt]
      end
      {good, bad}
    end)
  end

  defp validate_opts(opts, spec) do
    # Check all options for consistency with the spec
    Enum.reduce(spec[:options], {opts, []}, fn opt_spec, {opts, bad} ->
      opt_name = opt_name_to_atom(opt_spec)
      #formatted_name = format_option_no_arg(opt_spec)
      case Keyword.get_values(opts, opt_name) do
        [] ->
          if opt_spec[:required] do
            bad = bad ++ [missing_opt: opt_name]
          end

        values ->
          case opt_spec[:multival] do
            :error ->
              if not match?([_], values) do
                bad = bad ++ [duplicate_opt: opt_name]
                opts = Keyword.delete(opts, opt_name)
              end

            _ -> nil
          end
      end
      {opts, bad}
    end)
  end

  defp postprocess_opts(opts, spec) do
    # Add default values and accumulate repeated options
    Enum.reduce(spec[:options], opts, fn opt_spec, opts ->
      opt_name = opt_name_to_atom(opt_spec)
      if (default=opt_spec[:default]) && not Keyword.has_key?(opts, opt_name) do
        opts = opts ++ [{opt_name, default}]
      end
      if opt_spec[:multival] == :accumulate do
        values = Keyword.get_values(opts, opt_name)
        if values != [] do
          opts = Keyword.update!(opts, opt_name, fn _ -> values end)
        end
      end
      opts
    end)
  end

  # Execute help or version option if instructed to
  defp execute_opts_if_needed(opts, spec, config) do
    if Keyword.get(opts, :help) != nil and config[:exec_help] do
      cmd_name = spec[:name]
      if cmd_name == config[:name] do
        IO.puts Commando.help(spec)
      else
        IO.puts Commando.help(spec, cmd_name)
      end
      halt(config)
    end

    if Keyword.get(opts, :version) != nil and config[:exec_version] do
      IO.puts spec[:version]
      halt(config)
    end

    opts
  end

  defp validate_args(args, spec) do
    # FIXME: check argument types
    case check_argument_count(spec, args) do
      {:extra, index} ->
        {:error, {:bad_arg, Enum.at(args, index)}}

      {:missing, index} ->
        cond do
          arguments=spec[:arguments] ->
            name = Enum.at(arguments, index)[:name]
            {:error, {:missing_arg, name}}

          spec[:commands] ->
            {:error, :missing_cmd}
        end

      {:add, val} ->
        {:ok, args ++ [val]}

      nil ->
        {:ok, args}
    end
  end

  defp parse_cmd(args, spec, config) do
    commands = spec[:commands]
    [arg|rest_args] = args
    if cmd_spec=Enum.find(commands, fn %{name: name} -> name == arg end) do
      {:ok, do_parse(rest_args, cmd_spec, config)}
    else
      {:error, {:bad_cmd, arg}}
    end
  end

  defp execute_cmd_if_needed(%Cmd{subcmd: %Cmd{name: "help", arguments: args}},
                                      _cmd_spec, spec, %{exec_help: true}=config)
  do
    halt? = try do
      case args do
        [arg] ->
          IO.puts Commando.help(spec, arg)

        null when null in [nil, []] ->
          IO.puts Commando.help(spec)
      end
    rescue
      e in [ArgumentError] ->
        IO.puts e.message
        halt(config, 1)
    end
    if halt?, do: halt(config)
  end

  defp execute_cmd_if_needed(%Cmd{subcmd: %Cmd{}=cmd}=topcmd,
                                     %{action: f}, _, %{exec_commands: true})
  do
    f.(cmd, topcmd)
  end

  defp execute_cmd_if_needed(_, _, _, _), do: nil

  ###

  defp opt_name_to_atom(opt),
    do: binary_to_atom(opt[:name] || opt[:short])

  ###

  #defp format_option_no_arg(opt) do
    #cond do
      #name=opt[:name] ->
        #"--#{Util.name_to_opt(name)}"

      #short=opt[:short] ->
        #"-#{Util.name_to_opt(short)}"

      #true -> ""
    #end
  #end

  ###

  defp halt(config, status \\ 0) do
    case config[:halt] do
      true -> System.halt(status)
      :exit -> exit({Commando, status})
    end
  end

  ###

  defp check_argument_count(%{arguments: arguments}, args) do
    {required_cnt, optional_cnt} = Enum.reduce(arguments, {0, 0}, fn
      %{required: false}, {req_cnt, opt_cnt} -> {req_cnt, opt_cnt+1}
      _, {req_cnt, opt_cnt} -> {req_cnt + 1, opt_cnt}
    end)
    given_cnt = length(args)
    cond do
      given_cnt > required_cnt + optional_cnt ->
        {:extra, required_cnt + optional_cnt}

      given_cnt < required_cnt ->
        {:missing, given_cnt}

      arguments != [] ->
        # FIXME: half-baked solution
        default = hd(arguments)[:default]
        if given_cnt < required_cnt + optional_cnt && default do
          {:add, default}
        end

      true -> nil
    end
  end

  defp check_argument_count(%{commands: _}, args) do
    required_cnt = 1
    given_cnt = length(args)
    if given_cnt < required_cnt do
      {:missing, given_cnt}
    end
  end

  defp check_argument_count(_, []), do: nil

  defp check_argument_count(_, _), do: {:extra, 0}


  defp has_help_cmd(spec) do
    commands = spec[:commands]
    (commands
     && Enum.find(commands, fn cmd_spec -> cmd_spec[:name] == "help" end)) != nil
  end

  defp has_help_opt(spec) do
    spec[:options] != [] and hd(spec[:options])[:name] == "help"
  end

  ###

  defp parse_error(msg) do
    {:parse_error, msg}
  end
end
