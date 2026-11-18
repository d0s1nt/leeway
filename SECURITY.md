# Security

Leeway reads sign-in tokens that other tools keep on your Mac, so security
reports are taken seriously.

## Reporting a vulnerability

Please report privately through GitHub: on this repository, open **Security**, then
**Report a vulnerability**. Don't open a public issue for it.

Include what you found, how to reproduce it, and which version. Never include real
tokens, keychain contents or `auth.json` files; describe them instead.

## What the app does with credentials

- It reads tokens only from the locations listed in the README, and sends each one
  only to the vendor that issued it.
- It never stores tokens itself, never logs them, and has no server.
- By default it writes nothing that belongs to another tool. Only the opt-in
  "Renew Expired Sign-ins" setting writes renewed tokens back, to the same place the
  tool keeps them.
- Its only other network request is the manual Check for Updates, to GitHub's public
  releases API.

## Supported versions

Fixes go into the latest release.
