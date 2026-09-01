# AgentHub TOTP Manager Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a local AgentHub verification-code manager that stores TOTP seeds in the macOS Keychain, requires Touch ID or the local password for every secret read, and exposes a CLI for local agents.

**Architecture:** `AgentHubTOTPKit` is a shared Swift module. It stores only entry metadata in the AgentHub application-support directory and stores each seed as a Keychain generic-password item protected by `SecAccessControl` with `.userPresence`. The SwiftUI module uses the store for CRUD and one-shot code display. The `agenthub-totp` executable uses the same store and prints only a current six-digit code to stdout, so a scheduled agent can capture it without learning the seed. No Passwords UI automation or seed export is used.

**Tech Stack:** Swift 5.9, SwiftUI, Security.framework, LocalAuthentication, CryptoKit, XCTest, macOS 13+.

## Security and behavior decisions

- TOTP defaults to SHA-1, 6 digits, 30-second period, with otpauth URI import support for common authenticator exports.
- Keychain reads are explicitly user-presence protected. The app/CLI never logs or persists the seed or generated code.
- Listing entries is metadata-only and does not require biometric approval. `get` and UI reveal require approval.
- A headless launchd task cannot silently obtain a new code. When no interactive user session is available, the CLI fails closed and the existing AWS STS session remains unchanged.

## Acceptance criteria

1. Add, list, reveal, copy, and delete TOTP entries in AgentHub.
2. `agenthub-totp list` prints metadata only; `agenthub-totp get <id>` reads the protected seed, prompts for user presence, and prints one current code.
3. Seeds are absent from metadata JSON, logs, CLI arguments, and test artifacts.
4. Invalid Base32/URI input, missing entries, cancelled Touch ID, and unavailable Keychain access produce actionable errors and no partial writes.
5. Unit tests cover Base32 decoding, RFC 6238 vectors, metadata persistence, Keychain error handling seams, and CLI argument parsing.
6. Existing AgentHub account and dashboard tests remain green.

