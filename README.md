# SpamCop MailMate Bundle

A [MailMate](https://freron.com) bundle command that forwards the selected
message to your personal [SpamCop](https://www.spamcop.net) submission address
as a proper `message/rfc822` MIME attachment — the format SpamCop requires.

## Features

- One-keystroke submission: **⌃⌘S** (or via Command → SpamCop → Report Spam to SpamCop)
- First-run setup dialog — no manual config file editing required
- Delivers via local `sendmail` (Postfix, available on all macOS versions)
- Success notification via macOS Notification Centre
- No compiled code, no dependencies beyond what ships with macOS

## Requirements

- macOS with MailMate installed
- `python3` (available on macOS 12+; install via Homebrew on older systems)
- A [SpamCop reporting account](https://www.spamcop.net/anonsignup.shtml) and
  your personal submission address (`submit.XXXXXXXX@spam.spamcop.net`)

## Installation

```bash
# Clone (or copy) this repo into MailMate's Bundles folder
git clone https://github.com/yourname/spamcop-mailmate-bundle.git \
    ~/Library/Application\ Support/MailMate/Bundles/SpamCop.mmbundle
```

Or copy `SpamCop.mmbundle` directly:

```bash
cp -r SpamCop.mmbundle \
    ~/Library/Application\ Support/MailMate/Bundles/
```

MailMate picks up new bundles automatically — no restart required.

## Configuration

On first use, a dialog will ask for your SpamCop submission address and save
it to `~/.spamcop_mailmate` (mode 600). To change it later:

```bash
echo "submit.XXXXXXXX@spam.spamcop.net" > ~/.spamcop_mailmate
```

## Usage

1. Select one or more spam messages in MailMate
2. Press **⌃⌘S**, or choose **Command → SpamCop → Report Spam to SpamCop**
3. A macOS notification confirms the submission
4. SpamCop will email you a reply with authorised reporting URLs

## How It Works

SpamCop's email submission system requires the spam to arrive as a
`message/rfc822` MIME attachment. MailMate exposes the raw RFC 822 source of
the selected message via the `${rawFile}` format string, which the bundle
passes to the script as `$MM_RAW_FILE`. The script wraps it in a new message
and dispatches it via `sendmail`.

## Repository Layout

```
SpamCop.mmbundle/
├── Info.plist                    # Bundle metadata
├── Commands/
│   └── ReportSpamCop.mmCommand   # Command definition (input, key binding, env)
└── Support/
    └── bin/
        └── report_spamcop.sh     # Main script
README.md
.gitignore
```

## License

MIT
