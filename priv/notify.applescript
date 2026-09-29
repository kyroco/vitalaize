-- Sends one message from this Mac's Messages app.
-- osascript notify.applescript "<message>" "<number>" [iMessage|SMS]
-- SMS sends a plain text through the iPhone paired with this Mac (needs Text
-- Message Forwarding on the iPhone); it reaches numbers that are not on
-- iMessage, such as Google Voice. Without a third argument it uses iMessage.
on run argv
  set theText to item 1 of argv
  set theBuddy to item 2 of argv
  set theService to "iMessage"
  if (count of argv) > 2 then set theService to item 3 of argv
  tell application "Messages"
    if theService is "SMS" then
      set svc to 1st account whose service type = SMS
    else
      set svc to 1st account whose service type = iMessage
    end if
    send theText to participant theBuddy of svc
  end tell
end run
