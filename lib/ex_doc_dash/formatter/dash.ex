defmodule ExDocDash.Formatter.Dash do
	@moduledoc """
	Provide Dash.app documentation.
	"""

	alias ExDocDash.Formatter.Dash.Templates
	alias ExDoc.Formatter.HTML.Autolink

	@doc """
	Generate Dash.app documentation for the given modules
	"""
	def run(modules, config)  do
		config = make_docset(config)
		output = config.output

		{:ok, _pid} = create_index_database(config.formatter_opts[:docset_sqlitepath])

		generate_assets(output, config)
		generate_icon(config)
		has_readme = config.readme && generate_readme(output, modules, config)

		all = Autolink.all(modules)

		modules    = filter_list(:modules, all)
		exceptions = filter_list(:exceptions, all)
		protocols  = filter_list(:protocols, all)

		generate_overview(modules, exceptions, protocols, output, config)
		generate_list(:modules, modules, all, output, config, has_readme)
		generate_list(:exceptions, exceptions, all, output, config, has_readme)
		generate_list(:protocols, protocols, all, output, config, has_readme)

		content = Templates.info_plist(config, has_readme)
		:ok = File.write("#{output}/../../Info.plist", content)
		# :sqlite3.close(:index)

		config.formatter_opts[:docset_root]
	end

	defp make_docset(config) do
		output = Path.expand(config.output)
		docset_filename = "#{config.project} #{config.version}.docset"
		docset_root = Path.join(output, docset_filename)
		docset_docpath = Path.join(docset_root, "/Contents/Resources/Documents")
		docset_sqlitepath = Path.join(docset_root, "/Contents/Resources/docSet.dsidx")
		{:ok, _} = File.rm_rf(docset_root)
		:ok = File.mkdir_p(docset_docpath)
		formatter_opts = [
			docset_docpath: docset_docpath,
			docset_root: docset_root,
			docset_sqlitepath: docset_sqlitepath
		]
		Map.merge(config, %{output: docset_docpath, formatter_opts: formatter_opts})
	end

	defp create_index_database(database) do
		{:ok, pid} = :sqlite3.open(:index, [file: to_char_list(database)])
		:sqlite3.create_table(:index, "searchIndex", [
			{:id, :integer, [:primary_key, :unique]},
			name: :text,
			type: :text,
			path: :text
		])
		:sqlite3.sql_exec(:index, "CREATE UNIQUE INDEX anchor ON searchIndex (name, type, path);")
		{:ok, pid}
	end

	defp generate_overview(modules, exceptions, protocols, output, config) do
		content = Templates.overview_template(config, modules, exceptions, protocols)
		:ok = File.write("#{output}/overview.html", content)
	end

	defp assets do
		[
			{ templates_path("css/*.css"), "css" },
			{ templates_path("js/*.js"), "js" },
			{ templates_path("fonts/*"), "fonts" }
		]
	end

	defp generate_assets(output, _config) do
		Enum.each assets, fn({ pattern, dir }) ->
			output = "#{output}/#{dir}"
			File.mkdir output

			Enum.map Path.wildcard(pattern), fn(file) ->
				base = Path.basename(file)
				File.copy file, "#{output}/#{base}"
			end
		end
	end

	defp generate_icon(config) do
		destination_path = Path.join(config.formatter_opts[:docset_root], "icon.tiff")
		custom_icon_path = Path.join(config.source_root, "icon.tiff")
		template_icon_path = templates_path("icon.tiff")
		copy_path = if File.exists?(custom_icon_path), do: custom_icon_path, else: template_icon_path
		File.cp(copy_path, destination_path)
	end

	defp generate_readme(output, modules, config) do
		readme_path = Path.expand(readme_path(config, config.readme))
		write_readme(output, File.read(readme_path), modules, config)
	end

	defp readme_path(config, true), do: Path.join(config.source_root, "README.md")
	defp readme_path(config, path), do: Path.join(config.source_root, path)

	defp write_readme(output, {:ok, content}, modules, config) do
		content = Autolink.project_doc(content, modules)
		readme_html = Templates.readme_template(config, content) |> pretty_codeblocks
		File.write("#{output}/README.html", readme_html)
		true
	end

	defp write_readme(_, _, _, _) do
		false
	end

	@doc false
	# Helper to handle plain code blocks (```...```) without
	# language specification and indentation code blocks
	def pretty_codeblocks(bin) do
		Regex.replace(~r/<pre><code\s*(class=\"\")?>/,
		bin, "<pre class=\"codeblock\">")
	end

	@doc false
	# Helper to split modules into different categories.
	#
	# Public so that code in Template can use it.
	def categorize_modules(nodes) do
		[modules: filter_list(:modules, nodes),
		exceptions: filter_list(:exceptions, nodes),
		protocols: filter_list(:protocols, nodes)]
	end

	defp filter_list(:modules, nodes) do
		Enum.filter nodes, &match?(%ExDoc.ModuleNode{type: x} when not x in [:exception, :protocol, :impl], &1)
	end

	defp filter_list(:exceptions, nodes) do
		Enum.filter nodes, &match?(%ExDoc.ModuleNode{type: x} when x in [:exception], &1)
	end

	defp filter_list(:protocols, nodes) do
		Enum.filter nodes, &match?(%ExDoc.ModuleNode{type: x} when x in [:protocol], &1)
	end

	defp filter_list(:macros, nodes) do
		Enum.filter nodes, &match?(%ExDoc.ModuleNode{type: x} when x in [:macro], &1)
	end

	defp generate_list(scope, nodes, all, output, config, has_readme) do
		Enum.each nodes, &index_list(&1, all, output, config)
		Enum.each nodes, &generate_module_page(&1, all, output, config)
		content = Templates.list_page(scope, nodes, config, has_readme)
		File.write("#{output}/#{scope}_list.html", content)
	end

	defp index_list(%ExDoc.FunctionNode{}=node, module) do
		type = case node.type do
			:def -> "Function"
			:defmacro -> "Macro"
			:defcallback -> "Callback"
			_ -> "Record"
		end
		:sqlite3.write(:index, "searchIndex", [
			name: module<>"."<>node.id,
			type: type,
			path: module<>".html#"<>node.id
		])
		# IO.puts "    * FunctionNode: #{inspect node.id}"
	end
	defp index_list(%ExDoc.TypeNode{}=node, module) do
		:sqlite3.write(:index, "searchIndex", [
			name: module<>"."<>node.id,
			type: "Type",
			path: module<>".html#"<>node.id
			])
			# IO.puts "    * TypeNode: #{inspect node.id}"
		end
	defp index_list(node, _modules, _output, _config) do
		:sqlite3.write(:index, "searchIndex", [
			name: node.id,
			type: "Module",
			path: node.id<>".html"
		])
		# IO.puts "  * Node: #{inspect node.id}"
		Enum.each node.docs, &index_list(&1, node.id)
		Enum.each node.typespecs, &index_list(&1, node.id)
	end

	defp generate_module_page(node, modules, output, config) do
		content = Templates.module_page(node, config, modules)
		File.write("#{output}/#{node.id}.html", content)
	end

	defp templates_path(other) do
		Path.expand("dash/templates/#{other}", __DIR__)
	end
end