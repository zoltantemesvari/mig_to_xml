defmodule MigToXml do
  defmodule MigrationParser do
    def parse_migration(file_path) do
      file_path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> process_ast()
    end

    defp process_ast({:defmodule, _, [{:__aliases__, _, _}, [do: {:__block__, _, ast}]]}) do
      IO.inspect(ast, label: "AST")

      ast
      |> Enum.flat_map(&parse_command/1)
      |> Enum.reject(&is_nil/1)
    end

    defp parse_command({:use, _, _}), do: []

    defp parse_command({:def, _, [{:change, _, nil}, [do: commands]]}) do
      parse_commands(commands)
    end

    defp parse_command(other) do
      IO.inspect(other, label: "Unrecognized Command")
      []
    end

    defp parse_commands({:__block__, _, commands}) do
      Enum.map(commands, &parse_single_command/1)
    end

    defp parse_commands(single_command), do: [parse_single_command(single_command)]

    defp parse_single_command(
           {:create, _, [{:table, _, [table_name | _]}, [do: {:__block__, _, commands}]]}
         ) do
      IO.inspect({:create, table_name, commands}, label: "Create Command")
      %{action: :create, table: table_name, commands: Enum.map(commands, &parse_column/1)}
    end

    defp parse_single_command({:create, _, [{:index, _, [table_name, columns, opts]}]}) do
      IO.inspect({:create_index, table_name, columns, opts}, label: "Create Index Command")
      %{action: :create_index, table: table_name, columns: columns, opts: opts}
    end

    defp parse_single_command(
           {:alter, _, [{:table, _, [table_name | _]}, [do: {:__block__, _, commands}]]}
         ) do
      IO.inspect({:alter, table_name, commands}, label: "Alter Command")
      %{action: :alter, table: table_name, commands: Enum.map(commands, &parse_column/1)}
    end

    defp parse_single_command({:drop, _, [{:table, _, [table_name | _]}]}) do
      IO.inspect({:drop, table_name}, label: "Drop Command")
      %{action: :drop, table: table_name}
    end

    defp parse_single_command(other) do
      IO.inspect(other, label: "Unrecognized Single Command")
      nil
    end

    defp parse_column({:add, _, [column_name, {:references, _, [ref_table, opts]}, column_opts]}) do
      IO.inspect({:add, column_name, :references, ref_table, opts, column_opts},
        label: "Add Column with References"
      )

      %{
        action: :add,
        column: column_name,
        type: {:references, ref_table, opts},
        column_opts: column_opts
      }
    end

    defp parse_column({:add, _, [column_name, type, column_opts]}) do
      IO.inspect({:add, column_name, type, column_opts}, label: "Add Column")
      %{action: :add, column: column_name, type: type, column_opts: column_opts}
    end

    defp parse_column({:add, _, [column_name, type]}) do
      IO.inspect({:add, column_name}, label: "Add Column")
      %{action: :add, column: column_name, type: type}
    end

    defp parse_column({:remove, _, [column_name]}) do
      IO.inspect({:remove, column_name}, label: "Remove Column")
      %{action: :remove, column: column_name}
    end

    defp parse_column({:timestamps, _, _}) do
      IO.inspect(:timestamps, label: "Timestamps")
      %{action: :timestamps}
    end

    defp parse_column(other) do
      IO.inspect(other, label: "Unrecognized Column")
      nil
    end
  end

  defmodule MigrationToXML do
    def to_xml(parsed_data) do
      IO.inspect(parsed_data, label: "Parsed Data")

      parsed_data
      |> Enum.map(&convert_to_xml/1)
      |> Enum.join("\n")
      |> wrap_in_root()
    end

    defp convert_to_xml(%{action: :create, table: table_name, commands: commands}) do
      """
      <create table="#{table_name}">
        #{Enum.map(commands, &convert_command_to_xml/1) |> Enum.join("\n")}
      </create>
      """
    end

    defp convert_to_xml(%{action: :create_index, table: table_name, columns: columns, opts: opts}) do
      opts_str = opts_to_string(opts)
      columns_str = Enum.map(columns, &to_string/1) |> Enum.join(", ")

      """
      <create_index table="#{table_name}" columns="#{columns_str}" opts="#{opts_str}" />
      """
    end

    defp convert_to_xml(%{action: :alter, table: table_name, commands: commands}) do
      """
      <alter table="#{table_name}">
        #{Enum.map(commands, &convert_command_to_xml/1) |> Enum.join("\n")}
      </alter>
      """
    end

    defp convert_to_xml(%{action: :drop, table: table_name}) do
      "<drop table=\"#{table_name}\" />"
    end

    defp convert_command_to_xml(%{
           action: :add,
           column: column_name,
           type: {:references, ref_table, opts},
           column_opts: column_opts
         }) do
      opts_str = opts_to_string(opts)
      column_opts_str = opts_to_string(column_opts)

      "<add column=\"#{column_name}\" type=\"references\" ref_table=\"#{Atom.to_string(ref_table)}\" opts=\"#{opts_str}\" column_opts=\"#{column_opts_str}\" />"
    end

    defp convert_command_to_xml(%{
           action: :add,
           column: column_name,
           type: type,
           column_opts: column_opts
         })
         when is_atom(type) do
      column_opts_str = opts_to_string(column_opts)

      "<add column=\"#{column_name}\" type=\"#{Atom.to_string(type)}\" column_opts=\"#{column_opts_str}\" />"
    end

    defp convert_command_to_xml(%{action: :add, column: column_name, type: type}) do
      "<add column=\"#{Atom.to_string(column_name)}\" type=\"#{Atom.to_string(type)}\" />"
    end

    defp convert_command_to_xml(%{action: :remove, column: column_name}) do
      "<remove column=\"#{column_name}\" />"
    end

    defp convert_command_to_xml(%{action: :timestamps}) do
      "<timestamps />"
    end

    defp convert_command_to_xml(other) do
      IO.inspect(other, label: "Unrecognized Command to XML")
      nil
    end

    defp wrap_in_root(xml) do
      """
      <migrations>
        #{xml}
      </migrations>
      """
    end

    defp opts_to_string(opts) when is_list(opts) do
      Enum.map(opts, fn
        {k, v} -> "#{k}=#{value_to_string(v)}"
        k when is_atom(k) -> "#{k}=true"
        other -> IO.inspect(other, label: "Unhandled opts element"); "#{other}"
      end)
      |> Enum.join(", ")
    end

    defp opts_to_string(nil), do: ""

    defp opts_to_string(opts) do
      IO.inspect(opts, label: "Unhandled opts structure")
      ""
    end

    defp value_to_string(value) when is_tuple(value) do
      "{}"
    end

    defp value_to_string(value) when is_map(value), do: map_to_string(value)
    defp value_to_string(value), do: to_string(value)

    defp map_to_string(map) when map == %{} do
      "{}"
    end

    defp map_to_string(map) when is_map(map) do
      Enum.map_join(map, ", ", fn {key, val} -> ~s{"#{key}", "#{val}"} end)

    end

  end

  defmodule EctoMigrationToXML do
    def run(file_path, output_file_path) do
      file_path
      |> MigrationParser.parse_migration()
      |> MigrationToXML.to_xml()
      |> write_to_file(output_file_path)
    end

    defp write_to_file(xml_content, file_path) do
      File.write(file_path, xml_content)
      |> case do
        :ok -> IO.puts("XML successfully written to #{file_path}")
        {:error, reason} -> IO.puts("Failed to write XML to file: #{reason}")
      end
    end
  end

  # Run the conversion
  EctoMigrationToXML.run(
    "/home/temes/Downloads/sample2_mig.exs",
    "/home/temes/Downloads/testsample2_mig.xml"
  )
end
