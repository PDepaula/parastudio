# Testing the Windows zip

A checklist for the one person who tries the portable zip ([Windows](windows.md)) and tells the
captain how it went. The point is two numbers and one list: **how many minutes from the download to
the first time you press Play and a game window opens**, **every prompt Windows or the program
showed you**, and **which of those asked for an administrator**. The captain compares them with
your earlier try of the batch file.

You need a stopwatch (the clock on your phone), a pen or a notes file, and the zip the captain sent.
Do not prepare anything first, and do not click "Unblock" on the zip: the warnings are part of what is
being measured. If you already have git, Claude or Codex on this PC, say so in your notes; that is fine.

## Write down while you go

Copy this table into a note and fill the right column. Times are minutes since you started the
stopwatch.

| What happened | Time |
|---|---|
| Start the stopwatch at the moment you click download | 0:00 |
| The zip has finished downloading | |
| The zip is extracted (the folder `Paraloop-Studio` is open) | |
| You double-clicked `Paraloop-Studio.exe` | |
| The black window says it is starting Studio | |
| Studio is open in your browser | |
| Your first message to the producer got an answer | |
| You pressed Play and a game window opened (**the number the captain wants**) | |

If a step fails or you give up, write the time and what the window said, and send it anyway. A
failure is a result.

## Write down every prompt

A prompt is anything that stops and waits for you: a Windows box, a question in the black window, a
browser question, a sign-in. For each one write what it said (a photo of the screen is best), what you
clicked, and whether it asked for an **administrator**. An administrator prompt is the blue and yellow
shield or a box that says "Do you want to allow this app to make changes to your device?", or any
request for an administrator password.

| # | Where | What it said | What you clicked | Administrator? |
|---|---|---|---|---|
| 1 | | | | |

Things that often show up, so you know them when you see them:

- **"Windows protected your PC"** (SmartScreen) when you double-click the `.exe`. Click More info,
  then Run anyway. Count it as one prompt, not an administrator one.
- **A Windows Security / antivirus notice** about the file. Write down its words.
- **"Do you want to allow this app to make changes to your device?"**: administrator. Say which program.
- **The black window asking `Install git now? (y/n, Enter means no)`**: only if your PC has no git. Count
  it, and whether winget then showed its own boxes.
- **A Windows Firewall box** ("allow access") when Studio or the game starts.
- **Your browser** asking to open a link or allow something.
- **Claude or Codex asking you to sign in, or to trust the folder.**

## When you are done

Send the captain:

1. The two tables (a photo of handwriting is fine).
2. The file `tmp\launcher.log` from inside the `parastudio` folder (it says, with times, what each step
   did and how long the first start took; it holds nothing secret).
3. Anything that confused you, in your own words, even if it is small: where you hesitated, what you
   expected to see, which sentence you did not understand.

## Questions the captain will answer from your notes

| Question | Where the answer comes from |
|---|---|
| Minutes to first Play, and how that compares with the batch file try | The last row of the time table |
| How much of that was the zip (download, extract) and how much the first start | The rows between |
| How many prompts, and how many were for an administrator | The prompt table |
| Did the program say anything you could not follow | Your own words |
| Did the compiler and Nim in the zip work, with nothing installed | `tmp\launcher.log` |
