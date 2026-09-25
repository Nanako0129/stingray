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
#   · The answer is a record carrying <cross-session-message … from-name="X">.
# A send is pending when no such record from its target follows it.
. as $all
| [ range(0; length) as $k | $all[$k]
    | select(.type == "assistant") | (.message.content // [])[]?
    | select(.type == "tool_use" and .name == "SendMessage")
    | {k: $k, id: .id, to: ((.input.to // "") | tostring)} ] as $sends
| [ .[] | select(.type == "user") | (.message.content // [])[]?
    | select(.type == "tool_result")
    | select((.content | tostring) | contains("another Claude session"))
    | .tool_use_id ] as $cross
| [ range(0; length) as $k | ($all[$k] | tostring) as $s
    | select($s | contains("cross-session-message")) | {k: $k, s: $s} ] as $incoming
| [ $sends[]
    | select(.to != "") | . as $snd
    | select($cross | index($snd.id))
    | select([ $incoming[]
               | select(.k > $snd.k
                        and ((.s | contains("from-name=\\\"" + $snd.to + "\\\""))
                             or (.s | contains("from-name=\"" + $snd.to + "\"")))) ]
             | length == 0)
    | .to ]
| unique | .[]
