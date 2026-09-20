# Tool names called during THIS turn, read from the session transcript.
#
# Transcript facts measured on Claude Code v2.1.278 (2026-09-21):
#   · Every content block of one assistant message is its own jsonl record,
#     all sharing a message id. "This record has no tool_use" therefore does
#     not mean "this turn called no tools".
#   · promptId is present only on user records. On assistant records it is
#     null, so it cannot be used to filter them — only to locate where the
#     turn begins.
#
# Slice: find the user record whose promptId matches this turn and whose
# content is not a tool_result, then take everything from there to the end of
# the file. A Stop hook fires at the end of the turn, so "to the end" is exact.
[ .[] | select(.type == "user" or .type == "assistant") ] as $e
| ( [ $e
      | to_entries[]
      | select(.value.type == "user" and .value.promptId == $pid)
      | select(
          ((.value.message.content // []) | type) != "array"
          or (((.value.message.content // []) | map(.type) | index("tool_result")) == null)
        )
      | .key ] | first ) as $start
| if $start == null then "tool list for this turn unavailable"
  else
    [ $e[$start:][]
      | select(.type == "assistant")
      | (.message.content // [])[]?
      | select(.type == "tool_use")
      | .name ] as $n
    | if ($n | length) == 0 then "no tools were called"
      else "\($n | length) call(s): \($n | unique | join(", "))"
      end
  end
