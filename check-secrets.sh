#!/bin/zsh
# Fails if anything that looks like a credential or a personal identifier is in the tracked files, the git
# history, or a built release. Run before pushing; installed as a pre-push hook by `./check-secrets.sh --install`.
cd "$(dirname "$0")"
if [ "$1" = "--install" ]; then
  printf '#!/bin/sh\nexec "$(git rev-parse --show-toplevel)/check-secrets.sh"\n' > .git/hooks/pre-push
  chmod +x .git/hooks/pre-push; echo "pre-push hook installed"; exit 0
fi
# Credential shapes: JWTs, vendor API keys and OAuth secrets, GitHub tokens, bearer values, private keys.
PAT='eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}|sk-ant-[A-Za-z0-9_-]{10,}|sk-[A-Za-z0-9]{32,}|xai-[A-Za-z0-9]{20,}|GOCSPX-[A-Za-z0-9_-]{10,}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|Bearer [A-Za-z0-9._-]{30,}|BEGIN [A-Z ]*PRIVATE KEY|1//[0-9A-Za-z_-]{30,}|ya29\.[0-9A-Za-z_-]{30,}'
# Personal identifiers: home paths, email addresses (other than no-reply ones), account and user ids.
PII='/Users/[a-z][a-z0-9_-]*/|[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.(com|co\.uk|ai|io|net|org)\b|user-[A-Za-z0-9]{20,}|user_[0-9A-Z]{20,}'
ALLOW='noreply@anthropic\.com|users\.noreply\.github\.com|/Users/runner/'
fail=0
scan() {  # $1 = label, stdin = text
  hits=$(grep -nEo "$PAT|$PII" | grep -vE "$ALLOW" | cut -c1-80 | sort -u | head -20)
  if [ -n "$hits" ]; then echo "FOUND in $1:"; echo "$hits"; fail=1; else echo "clean: $1"; fi
}
# Per file, so a binary asset (icons, screenshots) can't make grep treat everything after it as binary.
git grep -I -h -o -E "$PAT|$PII" -- . 2>/dev/null | scan "tracked text files (working tree)"
git ls-files -o --exclude-standard -z | xargs -0 grep -I -h -o -E "$PAT|$PII" 2>/dev/null | scan "untracked text files about to be added"
# Binary assets: only image formats are expected, and they must not carry text metadata such as author or paths.
# Quiet when clean; a hit names the file and what was found.
for f in $(git ls-files | grep -E '\.(png|icns|jpg|jpeg|gif)$'); do
  out=$(strings -n 8 "$f" | scan "binary asset $f")
  [[ "$out" == clean:* ]] || { echo "$out"; fail=1; }
done
echo "checked: binary assets"
git log -p --all --format='commit %H %an <%ae>%n%B' 2>/dev/null | scan "git history (all commits, messages and authors)"
for bin in dist/*.app/Contents/MacOS/*(N); do strings -n 8 "$bin" | scan "release binary $bin"; done
for z in dist/*.zip(N); do unzip -l "$z" | awk '{print $4}' | grep -iE '\.env|auth\.json|creds|\.pem|\.key$' && { echo "FOUND credential-like file in $z"; fail=1; } || echo "clean: file list of $z"; done
git ls-files | grep -iE '(^|/)\.env|\.local\.env|auth\.json|oauth_creds|\.pem$|\.p12$|id_rsa' && { echo "FOUND credential-like file tracked"; fail=1; } || echo "clean: no credential files tracked"
exit $fail
