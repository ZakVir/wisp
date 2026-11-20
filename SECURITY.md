# Security

## What Wisp keeps and sends
- Voice is transcribed and answers are spoken on the Mac; audio never leaves it.
- While the shortcut is held, a screenshot and the question's text go to the AI provider you chose (NVIDIA NIM by
  default). Nothing is stored by Wisp, and logs contain no screenshot, audio, transcript or answer content.
- API keys are stored in the macOS Keychain, never in files or in this repository.

## Secrets in this repository
This repo contains no API keys, tokens or signing keys. Every push is scanned for secrets (`.github/workflows/secret-scan.yml`,
config in `.gitleaks.toml`), and GitHub secret scanning with push protection is on. The only key-shaped value is
Sparkle's update-signing **public** key in `app/project.yml`, which is public by design.

If you fork this, put your own keys in the app's Settings (Keychain) or in environment variables, and never commit
`.env` files, `.p8`/`.p12` files or Sparkle private keys (they are in `.gitignore`).

## Reporting a problem
Open a private security advisory on GitHub (Security tab > Report a vulnerability).
