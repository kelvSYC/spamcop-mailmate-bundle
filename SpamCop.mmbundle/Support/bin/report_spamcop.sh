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
#
# The raw message is passed in via the MM_RAW_FILE environment variable, which
# the .mmCommand wrapper sets to a temp file populated from MailMate's stdin
# (input = "raw").
#
# SpamCop requires the spam to be forwarded as a MIME attachment.  We use
# MailMate's own `emate` CLI to compose and send the report, which reuses
# MailMate's configured SMTP accounts (including OAuth2 and Keychain
# credentials) without any extra credential management.
#
# Usage: invoked automatically by MailMate via the bundle command definition.

set -euo pipefail

EMATE="/Applications/MailMate.app/Contents/Resources/emate"
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

# ── 3. Verify emate is available ─────────────────────────────────────────────

if [[ ! -x "$EMATE" ]]; then
    osascript -e 'display alert "SpamCop: emate not found. Is MailMate installed in /Applications?" as critical'
    exit 1
fi

# ── 4. Send via emate ───────────────────────────────────────────────────────
#
# emate mailto --send-now composes and immediately sends the message using
# MailMate's configured SMTP accounts.  The raw spam is attached as a .eml
# file so SpamCop can parse its headers.
#
# We rename the temp file to have a .eml extension so that emate (and the
# receiving MTA) can identify it as an email message.

EML_FILE="${MM_RAW_FILE}.eml"
cp "$MM_RAW_FILE" "$EML_FILE"

SAFE_SUBJECT="${MM_SUBJECT:-spam report}"

# Build the emate command
EMATE_ARGS=(
    mailto
    --to "$SUBMISSION_ADDRESS"
    --subject "[SpamCop] ${SAFE_SUBJECT}"
    --send-now
)

# If MM_FROM is set (passed from the .mmCommand environment), use it to
# select the sending identity.  This auto-matches the account that received
# the spam.  If unset or empty, emate picks the default identity.
if [[ -n "${MM_FROM:-}" ]]; then
    EMATE_ARGS+=(--from "$MM_FROM")
fi

# Attach the raw spam message
EMATE_ARGS+=("$EML_FILE")

if ! "$EMATE" "${EMATE_ARGS[@]}" 2>/tmp/spamcop_emate_err.log; then
    ERROR_MSG=$(cat /tmp/spamcop_emate_err.log 2>/dev/null || echo "Unknown error")
    osascript -e "display alert \"SpamCop: Failed to send report.\" message \"${ERROR_MSG}\" as critical"
    rm -f "$EML_FILE" /tmp/spamcop_emate_err.log
    exit 1
fi

rm -f "$EML_FILE" /tmp/spamcop_emate_err.log

# ── 5. Notify success ─────────────────────────────────────────────────────────

osascript -e "display notification \"Spam forwarded to SpamCop.\" with title \"SpamCop\" subtitle \"Submitted to ${SUBMISSION_ADDRESS}\""
