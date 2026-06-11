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
# IMPORTANT — reentrancy:  `emate` does not send mail itself.  It hands a
# `mailto:` URL to the *already-running* MailMate.app via an AppleEvent and
# asks it to compose/send.  MailMate runs this bundle command synchronously:
# its main runloop is blocked until this script returns.  If we invoked emate
# and waited for it here, emate's AppleEvent could not be serviced (MailMate
# is busy waiting for us) — a reentrant deadlock that freezes MailMate until
# the AppleEvent times out (~120 s) and forces a kill.  To avoid this we fire
# emate in a fully detached background session (perl + POSIX::setsid, since
# macOS has no setsid(1)) and return immediately, freeing MailMate's runloop
# to handle the AppleEvent.  Success/failure is reported asynchronously.
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

# ── 4. Send via emate (detached) ─────────────────────────────────────────────
#
# The raw spam is attached as a .eml file so SpamCop can parse its headers.
# We copy the temp file to a .eml name so emate (and the receiving MTA) can
# identify it as an email message.  The .eml copy is used — not MM_RAW_FILE —
# because the .mmCommand wrapper deletes MM_RAW_FILE as soon as this script
# returns, which (by design) happens before the detached emate runs.

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

# Worker: runs in the detached session.  "$@" is the emate command + args.
# A brief sleep lets MailMate finish executing this command (freeing its
# runloop) before emate's AppleEvent arrives.  Result is reported via the
# GUI notification/alert, which survives setsid (the Mach bootstrap port is
# inherited through the process tree, not the POSIX session).
read -r -d '' SPAMCOP_WORKER <<'WORKER_EOF' || true
sleep 1
if "$@" 2>"$SPAMCOP_ERR_LOG"; then
    osascript -e "display notification \"Spam forwarded to SpamCop.\" with title \"SpamCop\" subtitle \"Submitted to ${SPAMCOP_SUBMIT_ADDR}\""
    rm -f "$SPAMCOP_ERR_LOG"
else
    ERROR_MSG=$(cat "$SPAMCOP_ERR_LOG" 2>/dev/null || echo "Unknown error")
    osascript -e "display alert \"SpamCop: Failed to send report.\" message \"${ERROR_MSG}\" as critical"
fi
rm -f "$SPAMCOP_EML_FILE"
WORKER_EOF

export SPAMCOP_ERR_LOG="/tmp/spamcop_emate_err.log"
export SPAMCOP_EML_FILE="$EML_FILE"
export SPAMCOP_SUBMIT_ADDR="$SUBMISSION_ADDRESS"

# Detach into a new session and return immediately.  macOS has no setsid(1),
# so we daemonize with perl: the forked parent exits, the child (not a process
# group leader) calls setsid() to leave MailMate's process group, then execs
# the worker.  This guarantees the worker is never reaped when MailMate
# finishes the command.
/usr/bin/perl -MPOSIX -e 'fork and exit; POSIX::setsid(); exec @ARGV or die "$!";' \
    /bin/bash -c "$SPAMCOP_WORKER" _ "$EMATE" "${EMATE_ARGS[@]}" >/dev/null 2>&1 &
disown 2>/dev/null || true

# Return now so MailMate's runloop is free to service emate's AppleEvent.
exit 0
