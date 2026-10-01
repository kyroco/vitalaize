defmodule Wallboard.Collector.Proto.Tool do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "wallboard.collector.proto.Tool",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:TOOL_UNKNOWN, 0)
  field(:CLAUDE, 1)
  field(:CODEX, 2)
end

defmodule Wallboard.Collector.Proto.Status.State do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "wallboard.collector.proto.Status.State",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:STATE_UNKNOWN, 0)
  field(:WORKING, 1)
  field(:WAITING, 2)
  field(:IDLE, 3)
end

defmodule Wallboard.Collector.Proto.Status.Why do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "wallboard.collector.proto.Status.Why",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:WHY_UNKNOWN, 0)
  field(:PERMISSION, 1)
  field(:QUESTION, 2)
  field(:DIALOG, 3)
  field(:NETWORK, 4)
  field(:HELPER, 5)
  field(:GOAL, 6)
  field(:OTHER, 7)
end

defmodule Wallboard.Collector.Proto.FromCollector do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.FromCollector",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof(:body, 0)

  field(:hello, 1, type: Wallboard.Collector.Proto.Hello, oneof: 0)
  field(:event, 2, type: Wallboard.Collector.Proto.Event, oneof: 0)
  field(:ack, 3, type: Wallboard.Collector.Proto.Ack, oneof: 0)
end

defmodule Wallboard.Collector.Proto.Hello do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Hello",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:machine, 1, type: :string)
  field(:os, 2, type: :string)
  field(:version, 3, type: :string)
  field(:folders, 4, repeated: true, type: :string)
end

defmodule Wallboard.Collector.Proto.Event do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Event",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof(:body, 0)

  field(:session_id, 1, type: :string, json_name: "sessionId")
  field(:file, 2, type: :string)
  field(:position, 3, type: :uint64)
  field(:at, 4, type: :int64)
  field(:started, 10, type: Wallboard.Collector.Proto.SessionStarted, oneof: 0)
  field(:request, 11, type: Wallboard.Collector.Proto.Request, oneof: 0)
  field(:tool, 12, type: Wallboard.Collector.Proto.ToolTally, oneof: 0)
  field(:changes, 13, type: Wallboard.Collector.Proto.Changes, oneof: 0)
  field(:status, 14, type: Wallboard.Collector.Proto.Status, oneof: 0)
  field(:summary, 15, type: Wallboard.Collector.Proto.Summary, oneof: 0)
  field(:ended, 16, type: Wallboard.Collector.Proto.SessionEnded, oneof: 0)
  field(:counts, 17, type: Wallboard.Collector.Proto.Counts, oneof: 0)
end

defmodule Wallboard.Collector.Proto.SessionStarted do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.SessionStarted",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:tool, 1, type: Wallboard.Collector.Proto.Tool, enum: true)
  field(:account, 2, type: :string)
end

defmodule Wallboard.Collector.Proto.Request do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Request",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:request_id, 1, type: :string, json_name: "requestId")
  field(:model, 2, type: :string)
  field(:effort, 3, type: :string)
  field(:input_tokens, 4, type: :uint64, json_name: "inputTokens")
  field(:output_tokens, 5, type: :uint64, json_name: "outputTokens")
  field(:cache_read_tokens, 6, type: :uint64, json_name: "cacheReadTokens")
  field(:cache_write_5m_tokens, 7, type: :uint64, json_name: "cacheWrite5mTokens")
  field(:cache_write_1h_tokens, 8, type: :uint64, json_name: "cacheWrite1hTokens")
  field(:cost, 9, type: :double)
  field(:subagent, 10, type: :bool)
end

defmodule Wallboard.Collector.Proto.ToolTally do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.ToolTally",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:name, 1, type: :string)
  field(:calls, 2, type: :uint64)
  field(:errors, 3, type: :uint64)
end

defmodule Wallboard.Collector.Proto.Changes do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Changes",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:lines_added, 1, type: :uint64, json_name: "linesAdded")
  field(:lines_removed, 2, type: :uint64, json_name: "linesRemoved")
  field(:files_touched, 3, type: :uint64, json_name: "filesTouched")
end

defmodule Wallboard.Collector.Proto.Status do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Status",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:state, 1, type: Wallboard.Collector.Proto.Status.State, enum: true)
  field(:why, 2, type: Wallboard.Collector.Proto.Status.Why, enum: true)
  field(:tool, 3, type: :string)
  field(:since, 4, type: :int64)
end

defmodule Wallboard.Collector.Proto.Summary do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Summary",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:title, 1, type: :string)
  field(:first_prompt, 2, type: :string, json_name: "firstPrompt")
  field(:last_prompt, 3, type: :string, json_name: "lastPrompt")
  field(:folder, 4, type: :string)
  field(:branch, 5, type: :string)
  field(:repo, 6, type: :string)
  field(:prs, 7, repeated: true, type: Wallboard.Collector.Proto.PullRequest)
  field(:model, 8, type: :string)
  field(:effort, 9, type: :string)
  field(:version, 10, type: :string)
  field(:entrypoint, 11, type: :string)
end

defmodule Wallboard.Collector.Proto.PullRequest do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.PullRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:url, 1, type: :string)
  field(:number, 2, type: :uint64)
  field(:repo, 3, type: :string)
end

defmodule Wallboard.Collector.Proto.SessionEnded do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.SessionEnded",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Wallboard.Collector.Proto.Counts do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Counts",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:prompts, 1, type: :uint64)
  field(:turns, 2, type: :uint64)
  field(:turn_ms, 3, type: :uint64, json_name: "turnMs")
  field(:api_ms, 4, type: :uint64, json_name: "apiMs")
  field(:tool_ms, 5, type: :uint64, json_name: "toolMs")
  field(:compactions, 6, type: :uint64)
  field(:api_errors, 7, type: :uint64, json_name: "apiErrors")
  field(:retries, 8, type: :uint64)
  field(:aborted, 9, type: :uint64)
  field(:denials, 10, type: :uint64)
  field(:peak_context, 11, type: :uint64, json_name: "peakContext")
  field(:context_window, 12, type: :uint64, json_name: "contextWindow")
  field(:korium, 13, type: Wallboard.Collector.Proto.Korium)
end

defmodule Wallboard.Collector.Proto.Korium do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Korium",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:searches, 1, type: :uint64)
  field(:search_hits, 2, type: :uint64, json_name: "searchHits")
  field(:saves, 3, type: :uint64)
  field(:save_errors, 4, type: :uint64, json_name: "saveErrors")
  field(:code_searches, 5, type: :uint64, json_name: "codeSearches")
  field(:code_hits, 6, type: :uint64, json_name: "codeHits")
  field(:index, 7, type: :uint64)
  field(:other, 8, type: :uint64)
end

defmodule Wallboard.Collector.Proto.Ack do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Ack",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:id, 1, type: :uint64)
end

defmodule Wallboard.Collector.Proto.FromHub do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.FromHub",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  oneof(:body, 0)

  field(:id, 1, type: :uint64)
  field(:resume, 2, type: Wallboard.Collector.Proto.Resume, oneof: 0)
  field(:back_soon, 3, type: Wallboard.Collector.Proto.BackSoon, json_name: "backSoon", oneof: 0)
  field(:disconnected, 4, type: Wallboard.Collector.Proto.Disconnected, oneof: 0)
  field(:answer, 5, type: Wallboard.Collector.Proto.Answer, oneof: 0)
end

defmodule Wallboard.Collector.Proto.Resume do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Resume",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:points, 1, repeated: true, type: Wallboard.Collector.Proto.ResumePoint)
end

defmodule Wallboard.Collector.Proto.ResumePoint do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.ResumePoint",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field(:session_id, 1, type: :string, json_name: "sessionId")
  field(:file, 2, type: :string)
  field(:position, 3, type: :uint64)
end

defmodule Wallboard.Collector.Proto.BackSoon do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.BackSoon",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Wallboard.Collector.Proto.Disconnected do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Disconnected",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end

defmodule Wallboard.Collector.Proto.Answer do
  @moduledoc false

  use Protobuf,
    full_name: "wallboard.collector.proto.Answer",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3
end
