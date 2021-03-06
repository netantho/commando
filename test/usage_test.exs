defmodule CommandoTest.UsageTest do
  use ExUnit.Case

  test "basic command" do
    assert usage(name: "tool") == "tool"
  end

  test "just arguments" do
    assert usage_args([[]]) == "tool <arg>"
    assert usage_args([[name: "path"]]) == "tool <path>"
    assert usage_args([[name: "path", required: false]]) == "tool [<path>]"
    assert usage_args([[name: "path"], [name: "port", required: false]])
           == "tool <path> [<port>]"
  end

  test "vararg" do
    assert usage_args([
      [name: "r1"],
      [name: "o1", required: false],
      [name: "r2", nargs: :inf],
    ]) == "tool <r1> [<o1>] <r2> [<r2>...]"

    assert usage_args([
      [name: "r1"],
      [name: "o1", required: false],
      [name: "r2", nargs: :inf, required: false],
    ]) == "tool <r1> [<o1>] [<r2>...]"
  end

  test "named args" do
    assert usage_args([
      [name: "r1", argname: "path"],
      [name: "o1", argname: "other", required: false],
    ]) == "tool <path> [<other>]"
  end

  test "optional args" do
    assert usage_args([
      [name: "path", required: false, default: "."],
      [name: "port"],
    ]) == "tool [<path>] <port>"
  end

  test "just options" do
    assert usage([
      name: "tool", options: [[name: :hi]],
    ]) == "tool [options]"

    assert usage([
      name: "tool", list_options: :short, options: [[name: :hi]],
    ]) == "tool"

    assert usage([
      name: "tool", list_options: :long, options: [[short: :h]],
    ]) == "tool"

    assert usage([
      name: "tool", list_options: :short, options: [[name: :hi], [short: :h]],
    ]) == "tool [-h]"

    assert usage([
      name: "tool", list_options: :long, options: [[name: :hi], [short: :h]],
    ]) == "tool [--hi=<hi>]"

    assert usage([
      name: "tool", list_options: :all, options: [[name: :hi], [short: :h]],
    ]) == "tool [--hi=<hi>] [-h]"

    assert usage([
      name: "tool", list_options: :all, options: [[name: :hi, short: :h]],
    ]) == "tool [-h <hi>|--hi=<hi>]"

    assert usage([
      name: "tool", list_options: :all,
      options: [[name: :hi, short: :h, argtype: :boolean]],
    ]) == "tool [-h|--hi]"

    assert usage([
      name: "tool", list_options: :short,
      options: [[name: :hi, short: :h, argtype: :boolean, required: true]],
    ]) == "tool -h"

    assert usage([
      name: "tool", list_options: :long,
      options: [[name: :hi, short: :h, argtype: :boolean, required: true]],
    ]) == "tool --hi"

    assert usage([
      name: "tool", list_options: :all,
      options: [[name: :hi, short: :h, argtype: :boolean, required: true]],
    ]) == "tool {-h|--hi}"
  end

  test "multiple short options" do
    spec = [
      name: "tool",

      list_options: :short,

      options: [
        [short: :a, argtype: :boolean],
        [name: "config"],
        [short: :b, argtype: :boolean],
      ],
    ]

    assert usage(spec) == "tool [-a] [-b]"
  end

  test "options and arguments" do
    assert usage([
      name: "tool",
      arguments: [[]],
      options: [[name: "hi"]],
    ]) == "tool [options] <arg>"

    assert usage([
      name: "tool",
      arguments: [[name: "arg1"], [name: "arg2", required: false]],
      options: [[name: :hi], [short: :h, argname: "value"]],
      list_options: :all,
    ]) == "tool [--hi=<hi>] [-h <value>] <arg1> [<arg2>]"
  end

  test "command with prefix" do
    prefix = [prefix: "prefix", name: "tool"]

    assert usage(prefix) == "prefix tool"

    spec = prefix ++ [arguments: [[name: "hi"]]]
    assert usage(spec) == "prefix tool <hi>"

    spec = prefix ++ [options: [[name: :hi]], list_options: :long]
    assert usage(spec) == "prefix tool [--hi=<hi>]"
  end

  test "subcommands" do
    spec = [
      prefix: "pre",
      name: "tool",
      options: [[name: :log, argtype: :boolean], [short: :v]],
      commands: [
        [name: "cmda", options: [[name: :opt_a], [name: :opt_b, required: true]]],
        [name: "cmdb", options: [[short: :o], [short: :p]], arguments: [[]]],
      ],
    ]
    spec_all = [list_options: :all] ++ spec

    assert usage(spec) == "pre tool [options] <command> [...]"
    assert usage(spec_all) == "pre tool [--log] [-v] <command> [...]"
    assert usage(spec_all) == "pre tool [--log] [-v] <command> [...]"

    assert usage(spec, "cmda") == "pre tool cmda [options]"
    assert usage(spec_all, "cmda") == "pre tool cmda [--opt-a=<opt_a>] --opt-b=<opt_b>"

    assert usage(spec, "cmdb") == "pre tool cmdb [options] <arg>"
    assert usage(spec_all, "cmdb") == "pre tool cmdb [-o] [-p] <arg>"
  end

  test "autohelp subcommand" do
    spec = [
      name: "tool",
      options: [[name: :log, argtype: :boolean], [short: :v]],
      commands: [
        :help,
        [name: "cmda", options: [[name: :opt_a], [name: :opt_b, required: true]]],
        [name: "cmdb", options: [[short: :o], [short: :p]], arguments: [[]]],
      ],
    ]

    assert usage(spec, "help") == "tool help [<command>]"
  end

  defp usage(opts, cmd \\ nil) do
    Commando.new(opts) |> Commando.usage(cmd) |> String.rstrip
  end

  defp usage_args(args) do
    Commando.new([name: "tool", arguments: args]) |> Commando.usage()
  end
end
