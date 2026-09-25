# Sessions this one handed work to and is still waiting on, one name per line.
#
# A reply that says "handed to the Windows session, waiting for it to report"
# has a mechanism behind it the Stop payload does not show: SendMessage to
# another Claude session, whose answer arrives as a <cross-session-message>.
# Shape 3 counted only background_tasks and session_crons, so it blocked such a
# turn as a promise with nothing behind it.
#
# Transcript facts, read from a real session on Claude Code (2026-09-26):
#   · The send is an assistant tool_use named SendMessage, target in input.to.
#   · Its tool_result says "another Claude session" when the target is one. A
#     send to an in-process subagent says "queued for delivery … at its next
#     tool round" instead; that subagent is background work already, so it is
#     not counted here.
#   · The answer is a record whose text field BEGINS with the tag
#     <cross-session-message … from-name="X">, optionally after "Another Claude
#     session sent a message:". Read across 300 transcripts, it arrives as an
#     attachment (queued_command .prompt), a queue-operation (.content) or a
#     user record whose content is a string. Only those fields and only their
#     start count: a message that quotes the tag mid-text is not an answer, and
#     matching the tag anywhere let such a quote end a handoff still waiting.
# A send is pending when no answer from its target follows it.
def reply_head:
  if .type == "attachment" then (.attachment.prompt // "")
  elif .type == "queue-operation" then (.content // "")
  elif .type == "user" and ((.message.content | type) == "string") then .message.content
  else "" end
  | tostring;

. as $all
| [ range(0; length) as $k | $all[$k]
    | select(.type == "assistant") | (.message.content // [])[]?
    | select(.type == "tool_use" and .name == "SendMessage")
    | {k: $k, id: .id, to: ((.input.to // "") | tostring)} ] as $sends
| [ .[] | select(.type == "user") | (.message.content // [])[]?
    | select(.type == "tool_result")
    | select((.content | tostring) | contains("another Claude session"))
    | .tool_use_id ] as $cross
| [ range(0; length) as $k | ($all[$k] | reply_head) as $h
    | ($h | capture("^(?:Another Claude session sent a message:\\s*)?<cross-session-message [^>]*from-name=\"(?<n>[^\"]*)\"") // null) as $m
    | select($m != null) | {k: $k, from: $m.n} ] as $incoming
| [ $sends[]
    | select(.to != "") | . as $snd
    | select($cross | index($snd.id))
    | select([ $incoming[] | select(.k > $snd.k and .from == $snd.to) ] | length == 0)
    | .to ]
| unique | .[]
