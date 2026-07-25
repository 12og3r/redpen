-- "Red Pen" launcher.
--
-- A normal launch of ChatGPT cannot be injected (Electron needs the
-- remote-debugging port at process start), so this app quits a running
-- ChatGPT app and relaunches it through the redpen launcher, which enables
-- remote debugging and injects the renderer over CDP. The launcher is
-- started detached so it outlives this app (it lives until ChatGPT quits).
--
-- Before launching it: requires ChatGPT desktop + the codex CLI (blocks with a
-- dialog if either is missing), and installs the redpen-codex plugin if absent
-- (showing a progress bar).

-- LaunchServices gives a minimal PATH, so Homebrew/local bins must be added
-- explicitly or `codex` will not be found.
property shellPath : "/opt/homebrew/bin:/usr/local/bin:" & "/usr/bin:/bin:/usr/sbin:/sbin"
property repoMarketplace : "12og3r/redpen"

on runShell(commandText)
	return do shell script ("export PATH=" & (quoted form of shellPath) & "; " & commandText)
end runShell

on which(tool)
	try
		my runShell("command -v " & tool)
		return true
	on error
		return false
	end try
end which

on run
	set meDir to POSIX path of (path to me)
	set binPath to meDir & "Contents/Resources/bin/redpen-chatgpt-app"

	-- 1. Require the unified ChatGPT desktop app.
	try
		do shell script "test -d /Applications/ChatGPT.app"
	on error
		display dialog "ChatGPT desktop app isn't installed." & return & return & "Install the ChatGPT app first, then open Red Pen again." buttons {"OK"} default button "OK" with title "Red Pen" with icon stop
		return
	end try

	-- 2. Require the codex CLI.
	if not (my which("codex")) then
		display dialog "The Codex CLI isn't installed." & return & return & "Install it (for example: brew install codex), then open Red Pen again." buttons {"OK"} default button "OK" with title "Red Pen" with icon stop
		return
	end if

	-- 3. Ensure the redpen-codex plugin is installed.
	-- `codex plugin list` lists redpen-codex even when "not installed", so
	-- check the status column rather than mere presence.
	set pluginInstalled to false
	try
		if (my runShell("codex plugin list 2>/dev/null | grep 'redpen-codex' | grep -v 'not installed' | grep -q 'installed' && echo yes || echo no")) is "yes" then set pluginInstalled to true
	end try

	if not pluginInstalled then
		set progress description to "Setting up Red Pen"
		set progress additional description to "Installing the redpen-codex plugin…"
		set progress total steps to 100
		set progress completed steps to 0
		repeat with i from 1 to 35
			set progress completed steps to i
			delay 0.02
		end repeat

		-- Real install happens here (fake bar pauses, then finishes).
		try
			my runShell("codex plugin marketplace add " & repoMarketplace & " >/dev/null 2>&1 || true; codex plugin add redpen-codex@redpen >/dev/null 2>&1 || true")
		end try

		repeat with i from 36 to 100
			set progress completed steps to i
			delay 0.012
		end repeat
		set progress additional description to "Done"

		-- Verify it actually installed; if not, block rather than launch broken.
		set ok to false
		try
			if (my runShell("codex plugin list 2>/dev/null | grep 'redpen-codex' | grep -v 'not installed' | grep -q 'installed' && echo yes || echo no")) is "yes" then set ok to true
		end try
		if not ok then
			display dialog "Couldn't install the redpen-codex plugin automatically." & return & return & "Try manually:" & return & "  codex plugin marketplace add " & repoMarketplace & return & "  codex plugin add redpen-codex@redpen" buttons {"OK"} default button "OK" with title "Red Pen" with icon stop
			return
		end if
	end if

	-- 4. Quit a normally-running ChatGPT app so the launcher can start a fresh,
	-- debuggable instance (prompts once for Automation permission on first run).
	set chatgptRunning to (do shell script "/usr/bin/pgrep -f 'ChatGPT.app/Contents/MacOS/ChatGPT' >/dev/null 2>&1 && echo yes || echo no")
	if chatgptRunning is "yes" then
		try
			tell application "ChatGPT" to quit
		end try
		repeat 24 times
			set stillUp to (do shell script "/usr/bin/pgrep -f 'ChatGPT.app/Contents/MacOS/ChatGPT' >/dev/null 2>&1 && echo yes || echo no")
			if stillUp is "no" then exit repeat
			delay 0.25
		end repeat
	end if

	-- 5. Start the launcher detached so this app can exit immediately.
	my runShell("mkdir -p \"$HOME/.codex\"; ( " & quoted form of binPath & " launch >> \"$HOME/.codex/redpen-launcher.log\" 2>&1 & )")
end run
