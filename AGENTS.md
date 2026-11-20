# Working on Wisp (for AI agents and new contributors)

Start with [docs/DEVELOPER-GUIDE.md](docs/DEVELOPER-GUIDE.md): architecture, the life of one question, every module,
settings, models, releases, debug hooks and customization recipes.

Essentials:
- Code: `app/Packages/WispKit` (WispCore = pure logic + tests, WispMac = macOS), app target in `app/Wisp`,
  XcodeGen spec `app/project.yml`.
- Build and test: `cd app/Packages/WispKit && swift build && swift test`; run the app with `tools/run_app.sh`.
- Prompt changes: principle-based only, then run `python3 tools/run_prompt_suite.py tools/prompt_suite_200.json`.
- Privacy: no screenshot, audio, transcript or answer content in logs; keys never in the repo; never trigger a
  Keychain password prompt.
- Don't make Wisp speak on the user's Mac in automated tests; render audio to files.
- Commit small and push often; never merge into `main` without the owner's OK.
