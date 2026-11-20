import Foundation

/// What changed in each version, shown once after an update (and from the menu). Newest first. Each release adds
/// its entry here (short, friendly; the full notes are on the release page).
public enum WhatsNew {
    public struct Entry: Equatable, Sendable {
        public var version: String
        public var title: String
        public var points: [String]
    }

    public static let entries: [Entry] = [
        Entry(version: "2.10.3", title: "Answers from your screen", points: [
            "The most accurate model now answers every question, so “how do I…” points at the button on your screen instead of guessing a menu.",
            "Wisp sees the buttons inside apps like Claude, Slack and VS Code, and knows when an app is full screen.",
        ]),
        Entry(version: "2.10.2", title: "Talking again", points: [
            "Wisp no longer mistakes macOS's “Hey Siri” and dictation listening for a call, so it speaks its answers instead of only showing a card.",
        ]),
        Entry(version: "2.10.0", title: "Walkthroughs that wait for you", points: [
            "Ask “how do I…” and Wisp shows the first step, then watches: click, press a shortcut or type, and once the screen settles it looks again and shows the next step, until you're done.",
            "Say “what now?” or “I did it” for the next step, or press Esc to stop.",
        ]),
        Entry(version: "2.9.1", title: "A smarter model", points: [
            "NVIDIA retired Kimi K3, so Wisp now uses Nemotron 3.5 Super VL for most questions: 94% right on our real-app test, and usually talking within 2 seconds.",
            "Drawings now use Step 5 Preview, the free model that draws best. Quick how-to questions still get Nemotron's 1-second answers.",
        ]),
        Entry(version: "2.9.0", title: "Computer use, step by step", points: [
            "Wisp now looks before every step: if the Dock is hidden behind a full-screen app it brings it up, clicks the app (or Apps, types the name and clicks the result), and each click happens exactly as the cursor lands.",
            "Typing is checked against what the field really holds, and Wisp asks for the Accessibility permission instead of pretending when it doesn't have it.",
        ]),
        Entry(version: "2.8.0", title: "Light computer use", points: [
            "“Open Chess”, “open Notes and make a new note”, “open a new tab”, “open Instagram and search for …”: Wisp does it, and the cursor shows every click as it happens.",
            "With Better answers on it really clicks and types (Dock, Apps launcher, address bar, the site's search box). It does at most one small thing per request and never deletes, sends or buys.",
        ]),
        Entry(version: "2.7.0", title: "Wisp can search the web for you", points: [
            "Say “go online and search for best pizza in Austin” or “open YouTube”: the cursor clicks your browser, types in the address bar, and the page opens in a new tab.",
        ]),
        Entry(version: "2.6.0", title: "Wisp draws, and picks the right brain", points: [
            "Ask Wisp to draw something (“draw a cat”, “draw a star”, “draw a house with a tree”) and the cursor draws it on your screen, stroke by stroke.",
            "Smart routing: quick how-to questions go to the fast model, everything else to the smarter Kimi K3. Settings > AI.",
        ]),
        Entry(version: "2.5.23", title: "What's New in About", points: [
            "Settings > About has a What's New… button.",
        ]),
        Entry(version: "2.5.22", title: "Long selections too", points: [
            "Reading a long selection aloud also goes a part at a time, with “keep reading”.",
        ]),
        Entry(version: "2.5.21", title: "Keep reading", points: [
            "Long pages are read a part at a time: say “keep reading” to hear the next part.",
        ]),
        Entry(version: "2.5.20", title: "Two more quick actions", points: [
            "Explain the selected text simply, and make the selected text shorter.",
        ]),
        Entry(version: "2.5.19", title: "Better support reports", points: [
            "Check Wisp's Copy Report now includes how your recent questions went (no content), to help whoever supports you.",
        ]),
        Entry(version: "2.5.18", title: "Tips and countdowns", points: [
            "“What's a 20% tip on 45 dollars?”, “how many days until Christmas?”: answered instantly on your Mac.",
        ]),
        Entry(version: "2.5.17", title: "Guide updated", points: [
            "The getting-started guide now covers second opinions, silent answers, snoozing and asking History.",
        ]),
        Entry(version: "2.5.16", title: "Silent answers", points: [
            "In the question box, Command-Return asks without sound: the answer appears as captions and in the card.",
        ]),
        Entry(version: "2.5.15", title: "Snooze and extend", points: [
            "After a reminder goes off, say “snooze” (10 minutes) or “snooze for 5 minutes”. “Add 5 minutes to my timer” extends it.",
        ]),
        Entry(version: "2.5.14", title: "Privacy in the Check-up", points: [
            "Check Wisp now also shows your private apps, whether History is saved, and how many notes Wisp keeps.",
        ]),
        Entry(version: "2.5.13", title: "Forget one note", points: [
            "“Forget the note about parking” removes just that note.",
        ]),
        Entry(version: "2.5.12", title: "Reminders survive restarts", points: [
            "Timers and reminders are kept if Wisp restarts or updates; anything that came due meanwhile goes off right away.",
        ]),
        Entry(version: "2.5.11", title: "Links read nicely", points: [
            "Web addresses are read as “a link to example.com” instead of letter by letter.",
        ]),
        Entry(version: "2.5.10", title: "Your quick actions first", points: [
            "The question box shows the quick actions you use most recently at the top.",
        ]),
        Entry(version: "2.5.9", title: "Say Again on the card", points: [
            "The answer card now has a Say Again button next to Copy.",
        ]),
        Entry(version: "2.5.8", title: "Quieter in calls", points: [
            "During a call, Wisp's other replies (timers going off, read aloud, confirmations) are now captions too, not just answers.",
        ]),
        Entry(version: "2.5.7", title: "“What can you do?”", points: [
            "Wisp now answers with everything this version can do, and shows examples in a card.",
        ]),
        Entry(version: "2.5.6", title: "Ask your History", points: [
            "“What did you tell me about cropping earlier?” finds the answer in History and says it again.",
        ]),
        Entry(version: "2.5.5", title: "Math with spoken numbers", points: [
            "Instant math now understands numbers said as words: “what's twenty five percent of eighty?”.",
        ]),
        Entry(version: "2.5.4", title: "Read what you copied", points: [
            "Say “read what I copied” to hear your clipboard's text, read on your Mac.",
        ]),
        Entry(version: "2.5.3", title: "Tab to pick", points: [
            "In the question box, Tab picks the highlighted (or first) quick action.",
        ]),
        Entry(version: "2.5.2", title: "More quick actions", points: [
            "The question box now also offers Define a word…, Time in another city…, My notes, Try again with the other model, and storage.",
        ]),
        Entry(version: "2.5.1", title: "Timer in the menu bar", points: [
            "While a timer runs, its countdown shows next to Wisp's icon in the menu bar.",
        ]),
        Entry(version: "2.5.0", title: "Second opinion", points: [
            "Wrong answer? Say “try again” or “that's not right”: Wisp takes a fresh look and asks the other AI model.",
        ]),
        Entry(version: "2.4.4", title: "“Stop” just stops", points: [
            "Saying “stop”, “be quiet” or “never mind” now simply stops Wisp. To switch to captions only, say “captions only”.",
        ]),
        Entry(version: "2.4.3", title: "Tidier What's New", points: [
            "After a big jump in versions, What's New shows the newest 10 changes first, with the rest a click away.",
        ]),
        Entry(version: "2.4.2", title: "Calmer with Reduce Motion", points: [
            "With Reduce Motion on (System Settings > Accessibility), Wisp's cards, question box and closer look appear without fading.",
        ]),
        Entry(version: "2.4.1", title: "Spelling and quick picks", points: [
            "“How do you spell necessary?”, “flip a coin”, “roll a die”, “pick a number between 1 and 10”.",
        ]),
        Entry(version: "2.4.0", title: "Your Mac, at a glance", points: [
            "“How much storage do I have left?”, “what's my battery?”, “what version of macOS do I have?”, “how much memory does my Mac have?”: answered straight from your Mac.",
        ]),
        Entry(version: "2.3.3", title: "Faster History search", points: [
            "History opens ready to search: just start typing.",
        ]),
        Entry(version: "2.3.2", title: "Clearer question box", points: [
            "The question box's hint now says how to reach the quick actions (↓) and what Return will do.",
        ]),
        Entry(version: "2.3.1", title: "Updated guide", points: [
            "The getting-started guide on every release page now covers everything Wisp can do.",
        ]),
        Entry(version: "2.3.0", title: "Notes", points: [
            "Say “remember that my parking spot is B12”. Later: “what did I ask you to remember?”. Notes stay on your Mac and are never sent to the AI.",
        ]),
        Entry(version: "2.2.3", title: "Three new looks", points: [
            "New companion themes: Forest, Rose Gold and Graphite (a calm grey for the office). Settings > Companion.",
        ]),
        Entry(version: "2.2.2", title: "Your Wisp", points: [
            "Settings > About shows how many questions Wisp has answered, how quickly it starts talking, and how many it answered right on your Mac.",
        ]),
        Entry(version: "2.2.1", title: "Time and date, anywhere", points: [
            "“What time is it in Tokyo?”, “what's the date?”: answered instantly from your Mac's clock.",
        ]),
        Entry(version: "2.2.0", title: "A closer look", points: [
            "Small print? Point at it and say “magnify this” or “give me a closer look”: Wisp shows that area 2.5× bigger. Click or press Escape to close.",
        ]),
        Entry(version: "2.1.1", title: "Dictionary", points: [
            "“Define ephemeral”, “what's the definition of serendipity”: answered instantly from your Mac's own dictionary, with the full entry in a card.",
        ]),
        Entry(version: "2.1.0", title: "Instant math and conversions", points: [
            "“What's 15% of 80?”, “convert 5 miles to kilometers”, “72 fahrenheit in celsius”: answered exactly and instantly on your Mac, even offline.",
        ]),
        Entry(version: "2.0.1", title: "See what Wisp heard", points: [
            "Your spoken question appears for a moment before the answer, so a mishearing is easy to spot. Settings > General.",
        ]),
        Entry(version: "2.0.0", title: "Quick actions", points: [
            "The question box (double-tap Control) now suggests things Wisp can do as you type: summarize or read this page, copy text on screen, keyboard shortcuts, timers, translate, fix grammar, History and more. Use the arrow keys and Return.",
        ]),
        Entry(version: "1.9.2", title: "Pick your typing key", points: [
            "Double-tap Control, Option, Command or Shift to type a question: Settings > General.",
        ]),
        Entry(version: "1.9.1", title: "Better at “what's this?”", points: [
            "Wisp now looks where your pointer is when you let go of the shortcut, so you can move onto the thing while you ask.",
        ]),
        Entry(version: "1.9.0", title: "Summarize or translate a page", points: [
            "With nothing selected, “summarize this page”, “what are the key points of this email” or “translate this page into English” works on the whole window. Summaries are read aloud.",
        ]),
        Entry(version: "1.8.4", title: "Every answer in a card", points: [
            "Optional: Settings > General > Show spoken answers in a card too.",
        ]),
        Entry(version: "1.8.3", title: "Subtitle-style captions", points: [
            "Prefer captions in one place? Settings > General > Caption position > Bottom of the screen.",
        ]),
        Entry(version: "1.8.2", title: "Offline? Wisp says so", points: [
            "Without internet, Wisp tells you right away (and what still works) instead of waiting. The menu shows it too.",
        ]),
        Entry(version: "1.8.1", title: "Ask about what you copied", points: [
            "“What does what I copied mean?”, “translate my clipboard into French”: Wisp uses your clipboard only when you mention it.",
        ]),
        Entry(version: "1.8.0", title: "Timers and reminders", points: [
            "Say “set a timer for 5 minutes”, “remind me in 20 minutes to call Sam” or “remind me at 3 pm to send the report”. Wisp chimes and tells you when it's time.",
        ]),
        Entry(version: "1.7.0", title: "Quiet during calls", points: [
            "When another app is using the microphone (a Zoom, Teams or FaceTime call), Wisp answers with captions and a card instead of out loud.",
        ]),
        Entry(version: "1.6.0", title: "Read the page aloud", points: [
            "With nothing selected, “read this to me” (or “read this page to me”) reads the text of the window in front, in Wisp's voice.",
        ]),
        Entry(version: "1.5.0", title: "Writing help", points: [
            "Select text and say “make this more polite”, “fix the grammar”, “translate this into French” or “turn this into bullet points”. The new version appears in a card and on your clipboard, ready to paste.",
        ]),
        Entry(version: "1.4.0", title: "Claude, for teams", points: [
            "Settings > AI now offers Anthropic (Claude): Claude Sonnet 5.5, Haiku 4.5 or Opus 5.5 with your organization's Anthropic key.",
        ]),
        Entry(version: "1.3.1", title: "Talk faster, slower, or not at all", points: [
            "Say “talk faster”, “speak slower”, “normal speed”, “be quiet” (captions only) or “turn your voice back on”.",
        ]),
        Entry(version: "1.3.0", title: "Settings files", points: [
            "Set up several Macs the same way: Settings > General > Export Settings…, then Import Settings… on the other Mac. AI keys are never included.",
        ]),
        Entry(version: "1.2.0", title: "Copy text on screen", points: [
            "Say “copy the text on my screen” (or choose Copy Text on Screen in the menu): Wisp reads all the text you can see, even in images and videos, and puts it on the clipboard.",
        ]),
        Entry(version: "1.1.0", title: "Other languages", points: [
            "Type a question in another language (or ask for answers in one under About you): Wisp answers in that language and speaks it with your Mac's voice for it.",
        ]),
        Entry(version: "1.0.0", title: "Wisp 1.0: History", points: [
            "History… in the Wisp menu lists your questions and answers, with search, Copy and Say Again.",
            "It's cleared when Wisp quits, unless you turn on Keep history on this Mac (text only, never screenshots or audio).",
        ]),
        Entry(version: "0.9.0", title: "Keyboard shortcuts", points: [
            "Ask “what are the shortcuts here?”, or choose Keyboard Shortcuts in the Wisp menu, to see every shortcut of the app you're in, grouped by menu, with a filter.",
        ]),
        Entry(version: "0.8.0", title: "Private apps", points: [
            "Choose apps Wisp never sees in Settings > Privacy (for example your password manager or banking app). Their windows are left out of every screenshot.",
        ]),
        Entry(version: "0.7.0", title: "Answers you can read", points: [
            "After a typed question, the whole answer also appears in a card under the box, with Copy. Handy in meetings with the sound off.",
        ]),
        Entry(version: "0.6.2", title: "Setup tips", points: [
            "The last page of setup now shows a few more things to try.",
        ]),
        Entry(version: "0.6.1", title: "Say that again", points: [
            "Missed it? Hold the shortcut and say “say that again” or “repeat that”: Wisp repeats its last answer right away.",
        ]),
        Entry(version: "0.6.0", title: "Wisp Check-up", points: [
            "Something not working? Choose Check Wisp… in the menu: it tests every part of Wisp and shows the button that fixes each problem.",
        ]),
        Entry(version: "0.5.2", title: "Answer length", points: [
            "Prefer one-sentence answers, or a little more detail? Choose Short, Normal or Detailed in Settings > AI.",
        ]),
        Entry(version: "0.5.1", title: "Bigger captions", points: [
            "Choose Small, Medium or Large captions in Settings > General.",
        ]),
        Entry(version: "0.5.0", title: "Read aloud", points: [
            "Select text anywhere and say “read this to me”, or choose Read Selection Aloud in the Wisp menu. Wisp reads it word for word in its own voice, right on your Mac.",
        ]),
        Entry(version: "0.4.1", title: "Pause Wisp", points: [
            "Pause Wisp from its menu for an hour, until tomorrow, or until you resume: handy for presentations, games and calls.",
        ]),
        Entry(version: "0.4.0", title: "Step-by-step guidance", points: [
            "Ask how to do something. When Wisp points at the first step, click it and Wisp shows the next one, and so on until you're done.",
            "Press Escape or click somewhere else to stop. Turn it off in Settings > General.",
        ]),
        Entry(version: "0.3.9", title: "About you", points: [
            "Tell Wisp about yourself or how you like answers in Settings > AI > About you (\"I'm new to Macs\", \"keep it short\"). Every answer follows it.",
        ]),
        Entry(version: "0.3.8", title: "What's New", points: [
            "After an update, this window shows what changed since you last looked. Open it any time from the Wisp menu.",
        ]),
        Entry(version: "0.3.7", title: "Wisp knows what “this” is", points: [
            "Select some text and ask “what does this mean?”, or point at a button and ask “what does this do?” (with Better answers on).",
        ]),
        Entry(version: "0.3.6", title: "Type a question", points: [
            "Double-tap Control, type, and press Return. Handy in meetings and quiet places.",
        ]),
        Entry(version: "0.3.5", title: "Recent answers", points: [
            "Say the last answer again, copy it, or copy any of your last 10 answers from the Wisp menu.",
        ]),
        Entry(version: "0.3.4", title: "Escape stops Wisp", points: [
            "Press Escape while Wisp is talking or pointing to stop it right away.",
        ]),
        Entry(version: "0.3.3", title: "Better answers", points: [
            "With the optional Accessibility permission, Wisp reads the app's buttons and menus: it knows what's greyed out and points exactly at the right control.",
        ]),
    ]

    /// Entries newer than `lastSeen` and not newer than `current`, newest first.
    public static func since(_ lastSeen: String, upTo current: String) -> [Entry] {
        entries.filter { compare($0.version, lastSeen) == .orderedDescending && compare($0.version, current) != .orderedDescending }
    }

    /// Numeric version comparison ("0.3.10" > "0.3.9").
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
