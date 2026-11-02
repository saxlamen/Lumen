on run
  set out to ""
  tell application "System Events"
    tell process "System Settings"
      set w to front window
      set out to out & "面板: " & (name of w) & linefeed
      set lastName to ""
      set targetIdx to 0
      set idx to 0
      repeat with e in (entire contents of w)
        try
          set c to (class of e as string)
          if c is "static text" then
            set v to value of e
            if v is not missing value and v is not "" then set lastName to (v as string)
          else if c is "checkbox" then
            set idx to idx + 1
            if lastName is "Sunshine" and targetIdx is 0 then
              set targetIdx to idx
              set out to out & "找到 Sunshine 的開關: #" & idx & " 目前=" & (value of e) & linefeed
            end if
          end if
        end try
      end repeat
      if targetIdx is 0 then
        set out to out & "找不到 Sunshine 這一列" & linefeed
        return out
      end if
      -- rebuild the list so the element handle is fresh, then flip it off and back on
      set cbs to {}
      repeat with e in (entire contents of w)
        try
          if (class of e as string) is "checkbox" then set end of cbs to e
        end try
      end repeat
      click (item targetIdx of cbs)
      set out to out & "→ 撥成反的（現在=" & (value of item targetIdx of cbs) & "）" & linefeed
      delay 2
      set cbs to {}
      repeat with e in (entire contents of w)
        try
          if (class of e as string) is "checkbox" then set end of cbs to e
        end try
      end repeat
      click (item targetIdx of cbs)
      set out to out & "→ 撥回開（現在=" & (value of item targetIdx of cbs) & "）" & linefeed
      delay 2
      -- report whatever dialog the system put up
      repeat with p in (every process)
        try
          repeat with win in (windows of p)
            set btns to ""
            try
              set btns to name of every button of win
            end try
            if btns is not "" then
              set out to out & "對話框[" & (name of p) & "/" & (name of win) & "] 按鈕: " & btns & linefeed
            end if
          end repeat
        end try
      end repeat
    end tell
  end tell
  return out
end run
