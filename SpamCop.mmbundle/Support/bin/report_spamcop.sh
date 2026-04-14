#!/usr/bin/env bash
#
# report_spamcop.sh — forward the selected message to SpamCop for reporting.
#
# Configuration is read from ~/.spamcop_mailmate (a one-line file containing
# the user's personal SpamCop submission address, e.g.
#   submit.XXXXXXXX@spam.spamcop.net
# ).
#
# If the config file is absent, a one-time setup dialog is shown via osascript.
# The raw message file is passed in via the MM_RAW_FILE environment variable,
# which MailMate sets to the path of a temporary file containing the full RFC 822
# message source.
#
# SpamCop requires the spam to be forwarded as a MIME attachment (message/rfc822).
# We use Python's built-in email/smtplib or, preferably, the system's sendmail
# to construct and dispatch the wrapper message.
#
# Usage: invoked automatically by MailMate via the bundle command definition.

set -euo pipefail

CONFIG_FILE="$HOME/.spamcop_mailmate"

# ── 1. Resolve configuration ─────────────────────────────────────────────────

if [[ ! -f "$CONFIG_FILE" ]]; then
    SUBMISSION_ADDRESS=$(osascript <<'APPLESCRIPT'
set dialogResult to display dialog "Enter your personal SpamCop submission address:" ¬
    default answer "" ¬
    with title "SpamCop Setup" ¬
    buttons {"Cancel", "Save"} ¬
    default button "Save"
return text returned of dialogResult
APPLESCRIPT
    )

    if [[ -z "$SUBMISSION_ADDRESS" ]]; then
        osascript -e 'display alert "SpamCop setup cancelled — no address saved." as warning'
        exit 1
    fi

    printf '%s\n' "$SUBMISSION_ADDRESS" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
fi

SUBMISSION_ADDRESS=$(tr -d '[:space:]' < "$CONFIG_FILE")

if [[ -z "$SUBMISSION_ADDRESS" ]]; then
    osascript -e 'display alert "SpamCop submission address is empty. Please edit ~/.spamcop_mailmate." as critical'
    exit 1
fi

# ── 2. Locate the raw message ─────────────────────────────────────────────────

if [[ -z "${MM_RAW_FILE:-}" || ! -f "$MM_RAW_FILE" ]]; then
    osascript -e 'display alert "SpamCop: No raw message file found (MM_RAW_FILE unset or missing)." as critical'
    exit 1
fi

# ── 3. Build and send the wrapper message via Python ─────────────────────────
#
# The wrapper message:
#   From:    (local user — sendmail fills in the envelope)
#   To:      <submission address>
#   Subject: [SpamCop] <original subject>
#   Body:    brief note (SpamCop ignores it)
#   Attachment: the original spam as message/rfc822
#
# Python 3 is available on macOS 12+ via /usr/bin/python3; we also try the
# Homebrew path for older setups.

PYTHON=$(command -v python3 2>/dev/null || command -v /usr/local/bin/python3 2>/dev/null || true)

if [[ -z "$PYTHON" ]]; then
    osascript -e 'display alert "SpamCop: python3 not found. Please install Python 3." as critical'
    exit 1
fi

SAFE_SUBJECT="${MM_SUBJECT:-spam report}"

"$PYTHON" - <<PYEOF
import os, sys, smtplib
from email.message import EmailMessage
from email.headerregistry import Address
import socket

submission_address = "${SUBMISSION_ADDRESS}"
raw_file           = "${MM_RAW_FILE}"
subject_hint       = "${SAFE_SUBJECT}"

# Read the raw spam message bytes
with open(raw_file, "rb") as fh:
    spam_bytes = fh.read()

# Build the wrapper message
msg = EmailMessage()
msg["To"]      = submission_address
msg["Subject"] = f"[SpamCop] {subject_hint}"
msg.set_content(
    "Spam report submitted via MailMate SpamCop bundle.\n"
    "Please find the reported message attached.\n"
)

# Attach the original as message/rfc822 — required by SpamCop
msg.add_attachment(
    spam_bytes,
    maintype="message",
    subtype="rfc822",
    filename="spam.eml",
)

# Deliver via local sendmail (available on macOS with Postfix)
try:
    import subprocess
    proc = subprocess.run(
        ["/usr/sbin/sendmail", "-t", "-oi"],
        input=msg.as_bytes(),
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode())
except Exception as exc:
    print(f"ERROR: {exc}", file=sys.stderr)
    sys.exit(1)
PYEOF

# ── 4. Notify success ─────────────────────────────────────────────────────────

osascript -e "display notification \"Spam forwarded to SpamCop.\" with title \"SpamCop\" subtitle \"Submitted to ${SUBMISSION_ADDRESS}\""
