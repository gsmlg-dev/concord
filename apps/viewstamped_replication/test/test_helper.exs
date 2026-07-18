Path.wildcard(Path.join(__DIR__, "support/*.ex"))
|> Enum.sort()
|> Enum.each(&Code.require_file/1)

ExUnit.start()
