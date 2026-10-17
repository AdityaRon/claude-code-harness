# Guards

What each PreToolUse guard denies and asks. Moved from the README; the audit,
context and readability hooks are in [hooks.md](hooks.md).

A guard's deny blocks the call in every permission mode (a loaded mod is the
exception; see [known-limitations.md](known-limitations.md)). A guard's ask
comes to you even in auto mode: Claude Code's
[permission-modes doc](https://code.claude.com/docs/en/permission-modes), read
2026-10-16, says prompts forced by an ask rule or a hook are not removed by
switching to auto mode, "because auto mode still shows you those prompts". The
classifier decides only what no guard or rule names; see
[auto-mode.md](auto-mode.md).

## What each guard does

| Hook | Event | Behaviour |
|---|---|---|
| `env-guard` | PreToolUse → Bash | Blocks commands that read, dump, copy, or exfiltrate env values or dotfiles (`cat .env`, `printenv`, `echo $API_KEY`, `cp .env /tmp/x`, `dd if=.env`, `… < .env`, `curl --data @creds`, `nc`, `eval $(env)`, etc.). A jq filter or a grep/rg pattern is text, not a file: `grep -rn '\.env' src/` is a search. |
| `sensitive-file-guard` | PreToolUse → Read/Edit/Write/MultiEdit/NotebookEdit/**Grep** | Blocks access to `*.env`, `*.pem`, `*.key`, SSH keys, AWS creds, `.npmrc`, `.git-credentials`, `.pgpass`, `.kube/config`, `.ssh/config`, `.docker/config.json`, `credentials.json`, service-account JSON. Resolves symlinks so a symlinked path can't bypass. **Grep** prints file content like `Read` does, so it is guarded on the same list: its `path` is checked as a file *and* as a credentials directory (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, which a content search would dump wholesale), and its `glob` is checked in de-globbed form, so `*.env`, `**/.env*` and `*.{env,ts}` are all denied. Grep's `pattern` is the text being searched *for*, never a target: grepping source for `process.env.API_KEY` stays an ordinary read. |
| `git-guard` | PreToolUse → Bash | Denies force-push in every spelling (`--force`, `--force-with-lease`, a bundled short flag like `-fu`/`-qf`, a `+` refspec, `--mirror`), `reset --hard`, `clean -f`, writes into `.git/hooks` (the directory, so `cd .git/hooks && cat > pre-commit` counts), `core.hooksPath` tampering (including via `-c`), shell-body (`!`) aliases, `filter-branch`, broad `git add` (`.`, `./`, `:/`, `-A`, `--all`, including behind a flag like `git add -v .`). Asks before `branch -d/-D` unless a remote-tracking ref holds every named branch's tip. Normalizes `git -c k=v` / `-C dir` global-option prefixes, and (via `normalize_wrappers`) leading env assignments and wrapper commands, so neither can break the match. |
| `rm-guard` | PreToolUse → Bash | Denies recursive `rm` of `/`, `~`, `$HOME`, `.`, `..`, `*` or a top-level folder, `-f` or not, and any `rm -rf` (every spelling: `-fr`, `-r -f`, `--recursive --force`) outside this session's scratch folder. Inside `$CLAUDE_JOB_DIR/tmp`, or the sandbox's `/tmp/claude-<uid>/<job id>`, it runs: the folder comes from the hook's session id, a `..` or a command that sets `CLAUDE_JOB_DIR`, `HOME` or `TMPDIR` gets no allowance, and `cd` into scratch or `T=<scratch path>` earlier in the same command counts, unless the command holds a `(`: a cd inside a subshell does not last. Replaces the `Bash(rm -rf:*)` deny rules, which matched one spelling and refused the scratch folder 197 times in 49 days on one machine. |
| `config-guard` | PreToolUse → Bash/Write/Edit/MultiEdit/NotebookEdit | Asks before a write into `~/.claude/hooks` or to the scripts directly in `~/.claude` (`statusline.sh` runs outside the sandbox): `cp`/`mv`/`rm`/`ln`/`chmod`/`tee`/`sed -i`/`curl -o`/`>` from Bash, and the file tools. Denies moving or emptying `~/.claude` itself. Also asks before a write to a Claude Code settings file, a shell startup file (`~/.zshrc`, `~/.bashrc`, `~/.profile`, …), `~/.gitconfig` (including `git config --global`) or `~/Library/LaunchAgents`. Reads pass, and a write made from inside an interpreter is not seen. |
| `interpreter-guard` | PreToolUse → Bash | Asks before `python -c` / `node -e` / `ruby -e` / `perl -ne` / `php -r` / `bash -c` and heredocs when the payload references env vars, dotfiles, sockets, or subprocess APIs, including when wrapped in a command runner (`poetry run`, `env`, `timeout`, `nohup`, …). Raises the bar on the interpreter-bypass route, but string-obfuscated payloads can still evade a regex; the OS sandbox is the real containment. |
| `network-guard` | PreToolUse → Bash, WebFetch | Denies file-body uploads via `curl -d @…` / `-d@…` / `--data=@…`, `-F @…`, `-T`, **and pipe-to-shell remote code execution** (piping curl/wget into a shell or interpreter, process substitution, or command substitution). An interpreter running a local script file, or `python3 -m json.tool`, reads the download as data and is allowed. Prompts on `scp`/`rsync`/`sftp` to a remote host and on local HTTP servers. |
| `secret-scanner` | PreToolUse → Write/Edit/MultiEdit/NotebookEdit | Scans the payload before it hits disk; denies AWS keys, JWTs, PEM blocks, GitHub/Slack(token+webhook)/Stripe/Google/Anthropic/OpenAI(incl. `sk-proj-`) tokens and GCP service-account keys |
| `mod-gate` | PreToolUse → Write/Edit/MultiEdit/NotebookEdit | On a Claude Code mod's files, runs `claude plugin validate` on the mod as it will be after the write. Denies hooks that replace permission decisions (`tool.check`, `classic.PreToolUse`, `classic.PermissionRequest`, `plugin.register`, `engine.create`); otherwise tells you what the mod hooks and calls. Any other file exits in ~5 ms. See [known-limitations.md](known-limitations.md). |

## When a guard asks

| Hook | Triggers |
|---|---|
| `git-guard` | `git branch -D` of a branch whose tip no remote-tracking ref holds, or one it cannot check (a name in a variable, xargs, a `cd` first), `git push --delete`, `git push origin :branch`, `git remote set-url`, `git config user.email`, non-shell `git config alias.*`, glob staging (`git add '*.ts'`) |
| `interpreter-guard` | Long inline scripts with no obvious sensitive token |
| `kubectl-guard` | Every mutating `kubectl` verb (`delete`, `apply`, `patch`, `replace`, `edit`, `scale`, `drain`, `cordon`, `taint`, `exec` (except a non-interactive `exec … --` running `ls`, `id`, `df`, `hostname` and similar, or any command asked only for `--version`/`--help`; `cat`, `env`, `printenv` and `ps` still ask), `cp`, `run`, `debug`, `proxy`, `rollout undo/restart`, `auth reconcile`, `config use-context`, …) wherever the verb sits in the command, plus `get secret` in every spelling that returns the data (`secret/db-creds`, `pods,secrets`, `Secret`, `secrets.v1.`, and the `--raw /api/v1/…/secrets` path: credential materialisation), and any subcommand on neither list (fails closed). Only the resource *kind* is compared, so a CRD that merely starts with the word (`secretproviderclass`, `sealedsecrets`) stays a silent read. Exists because `kubectl` takes its global flags **before** the verb, so a prefix-matched rule like `Bash(kubectl delete:*)` misses `kubectl --namespace vm delete pod foo`: no allow/deny pair in `settings.json` can express this. Escalates rather than blocks: auto mode ships ~10 kubectl-specific `soft_deny` rules that clear when you name the target, and a hook `deny` would preempt all of them. Read-only verbs (`get`, `describe`, `logs`, `top`, `port-forward`, `rollout status`, `auth can-i`, `config view`, …) pass silently; flag *values* are skipped so `--context delete-me get pods` is still a read. |
| `network-guard` | `curl -X DELETE` (any host), a request body (`-X POST/PUT/PATCH`, `-d`, `--json`, `-F`, a bundled `-sXPOST` or `--request=`) to any host except this machine and hosts added with `net-allowlist.sh add --body` (a loopback body still asks for an admin API, or while a port-forward, `ssh -L`, socat, cloudflared or ngrok runs or appears in the command), `curl`/`wget`/`WebFetch` to a non-allowlisted domain. A GET to this machine (`127.x`, `localhost`, `::1`) is allowed, except a local admin API (ports 8001 `kubectl proxy`, 2375/2376 Docker, 8200 Vault, or Kubernetes API paths on any port), which asks; every URL in the command is checked, by the host curl actually connects to. Adding a host to this machine's allowlist (`net-allowlist.sh add`, or a write into `~/.claude/local-settings`) asks too |
| `sensitive-file-guard` | A Grep whose `path` is your home folder or above it, and a Grep `glob` with `?`, `[..]` or more than one brace group, which the credential check cannot read |
| `mod-gate` | A mod `claude plugin validate` gives no report for, and a mod that hooks `tool.call` or calls something that runs outside the guards (`$.process`, `$.http`, `$.fs.write`, …) |

## Allowlisting a wrapper script bypasses every guard

A PreToolUse hook sees only the top-level Bash command, never the `kubectl` or
`git` calls a script makes internally. `config/settings.json` ships no
`~/.claude/skills/*` allow entry, and one added in a local-settings fragment is
safest as a read-only probe: allowlisting a probe that creates and deletes
cluster resources would launder `kubectl-guard`, which would never see inside
it.
