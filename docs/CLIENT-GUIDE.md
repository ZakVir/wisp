# Getting started with Wisp

Wisp is a helper for your Mac. Hold **Control + Option**, ask a question out loud, and let go. Wisp answers in a
friendly voice with captions. When the question is about what's on your screen, a small cursor flies over and points
at the right spot. It never clicks or types for you.

You need a Mac with Apple silicon (M1 or newer) and macOS 15 or later.

## 1. Install (2 minutes)

1. Download **Wisp-x.y.z.dmg** from https://github.com/ZakVir/wisp-updates/releases/latest
2. Open it and drag **Wisp** onto **Applications**.
3. Open Wisp from your Applications folder.
4. The first time, macOS may say it can't check Wisp for malicious software. Click **Done**, then open
   **System Settings > Privacy & Security**, scroll down and click **Open Anyway** next to Wisp. You only do this once.

## 2. Setup (about 5 minutes)

The welcome guide walks you through everything:

- **What leaves your Mac:** your voice never does. A screenshot and your question's text go to the AI only while you
  hold the shortcut, and Wisp doesn't keep them.
- **Speech:** Wisp downloads its speech files (about 260 MB) by itself. You can carry on while it does.
- **AI:** click **Open NVIDIA's key page**, sign in or create a free account, choose **Generate API Key**, copy it and
  paste it into Wisp. (Or choose Custom to use your company's own OpenAI-compatible AI service.)
- **Permissions:** allow **Microphone**, **Input Monitoring** (so Wisp notices the shortcut) and **Screen Recording**
  (so Wisp can see what you're asking about). macOS may ask Wisp to quit and reopen; that's normal.
- **Try it out:** hold the shortcut and ask "What can you do?". You can also pick the shortcut, voice and cursor look.
- **Better answers (optional, recommended):** allow **Accessibility** so Wisp can read the buttons and menus of
  the app you're in, and any text you've selected. Answers get noticeably more accurate.

## 3. Everyday use

- Hold **Control + Option**, ask, let go. For example: "How do I export this as a PDF?", "Where's the Wi-Fi
  setting?", "What's 15% of 80?"
- **Type instead:** double-tap **Control**, type your question and press Return. The answer also appears in a card
  you can copy. The box also suggests quick actions as you type (↓ and Return to pick one).
- **Step by step:** ask "how do I…". When Wisp points at the first step, click it, and Wisp shows the next one.
- **"This":** select text and ask "what does this mean?", or point at a button and ask "what does this do?".
- **Read aloud:** select text and say "read this to me".
- **Shortcuts:** ask "what are the shortcuts here?" to see every keyboard shortcut of the app you're in.
- **Writing help:** select text and say "make this more polite", "fix the grammar", "translate this into Spanish" or
  "turn this into bullet points": the new version goes on your clipboard, ready to paste. With nothing selected,
  "summarize this page" reads you a short summary of the window.
- **Instant answers on your Mac:** math ("what's 15% of 80?"), conversions ("5 miles in km"), the time anywhere
  ("what time is it in Tokyo?"), definitions ("define ephemeral"), timers and reminders ("remind me in 20 minutes
  to call Sam"; "snooze" when it goes off; they survive restarts), and notes ("remember that my parking spot is
  B12").
- **A closer look:** point at small print and say "magnify this".
- **Wrong answer?** Say "try again" for a second opinion from the other AI model.
- **Silent:** in the question box, Command-Return answers without sound (captions and a card).
- **Copy text on screen:** "copy the text on my screen" (even from images and videos).
- **Missed it?** Say "say that again", or use **Say Last Answer Again** in the Wisp menu. **History…** lists
  your earlier questions and answers; "what did you tell me about cropping earlier?" finds one.
- To stop, press **Escape** (or use the shortcut again, or **Stop** in the Wisp menu).
- **Pause Wisp** (in its menu) for an hour or until tomorrow, for presentations. During calls Wisp answers quietly
  (captions and a card) by itself.
- Wisp lives in the menu bar at the top of your screen (the cursor icon). **Settings**, **History**, **Check Wisp**
  and **What's New** are there.
- Make it yours in **Settings**: **About you** (Settings > AI) tells Wisp how you like answers; **Answer length**,
  **Caption size** and position, voice and speed ("talk faster" works too); **Private apps** (Settings > Privacy)
  are apps Wisp never sees.

## Updates

Wisp updates itself. It checks once a day and installs updates quietly when you're not using it. After an update, a
**What's New** window shows what changed. Every version can also be downloaded from
https://github.com/ZakVir/wisp-updates/releases

## If something isn't working

- **Start with Check Wisp…** in the Wisp menu: it tests every part of Wisp and has a button that fixes each problem.
  **Copy Report** there gives you a report (no personal content) to send for help.
- **Wisp doesn't react to the shortcut:** open Wisp's menu: it tells you what's missing and opens the right setting.
  Also check that Wisp isn't paused.
- **macOS asks whether Wisp can keep seeing your screen:** choose **Allow**. macOS asks this now and then.
- **Anything else:** in **Settings > Permissions**, click **Copy Diagnostics** and send it to whoever set Wisp up for
  you. It contains versions and settings only, never anything you said or saw.
