# Computer Security Project: test machine

One throwaway **Debian 13** machine (a Docker container) on your own computer, for building and
testing scripts before you run them anywhere else. It has:

- root SSH login by password, and
- the Docker Engine API on port 2375 over plain HTTP with no authentication (a common
  misconfiguration, so you can practise talking to a remote Docker API).

## Start

Needs Docker with Compose (Linux, or Docker Desktop on macOS/Windows).

```bash
cp .env.example .env        # set ROOT_PASSWORD to something of your own
docker compose up -d --build
docker compose logs -f      # wait for "test machine ready"
```

- SSH: `ssh -p 2222 root@127.0.0.1`
- Docker API: `http://127.0.0.1:2375`

If those ports are taken on your computer, set `SSH_PORT` and `API_PORT` in `.env`.

Stop with `docker compose down`; `docker compose down -v` also wipes its inner Docker data.

## Try it

```bash
# Docker API by hand
curl -s http://127.0.0.1:2375/version
curl -s http://127.0.0.1:2375/containers/json
DOCKER_HOST=tcp://127.0.0.1:2375 docker run --rm hello-world   # docker CLI against the API

# Run a check on A and B and log the command, outputs and UTC times to evidence.log
scripts/example.sh ssh 'uname -a'
scripts/example.sh api /info

# Timing: 10 runs on A, then 10 on B, 3 s apart, every number reported
scripts/example.sh time ssh 'ls /usr/bin | wc -l' 10

# Compare two machines side by side and log every difference that could out a honeypot
scripts/fingerprint.sh

# Record a whole terminal session as plain text
script -q session.log
```

`scripts/fingerprint.sh` builds on `example.sh` for the honeypot-detection angle: in one SSH round
trip per machine it collects ~25 host signals (kernel, uptime, process and package counts, entropy,
containerization, monitoring agents, shell history, listening ports, ...), pulls `/version` and
`/info` from each Docker API, and writes three things to `fingerprint.log`:

- **SIGNALS** — a line-by-line diff of A against B; every differing line is something an attacker
  could use to tell the two apart.
- **DOCKER** — the same diff for the Docker API responses.
- **TELLS** — per machine, the classic honeypot giveaways it found (running in a container, freshly
  booted, empty root shell history, auditd watching, a sparse minimal image, low entropy, ...).

A and B both default to the local test machine, so by itself it compares the box to itself (empty
diff, matching tells — a self-test). Point them at two hosts with `A_HOST`/`A_SSH`/`A_API` and
`B_HOST`/`B_SSH`/`B_API` to compare a suspected decoy against a known-real box. The probes are
read-only heuristics; run them only on machines you are allowed to test.

`scripts/example.sh` is a starting point for your own script: it runs each check on two machines, A and B, and logs both. Here both default to this
test machine, so each check runs twice against the same box, which is enough to build and
debug the script. If you changed the ports, export `SSH_PORT` and `API_PORT` in your shell
too. To compare two real hosts later, set `A_HOST`, `A_SSH`, `A_API`, `B_HOST`, `B_SSH` and
`B_API`.

After `docker compose down` and a fresh `up`, the machine gets a new SSH host key and SSH warns
that the key changed. That's expected. Clear the old key with `ssh-keygen -R '[127.0.0.1]:2222'`,
or keep it apart with `SSH_OPTS="-o UserKnownHostsFile=$HOME/.ssh/test_known_hosts"`.

## Safety

- The ports are bound to `127.0.0.1` on purpose. An open Docker API is root on whatever can
  reach it, and the container runs `--privileged` (needed for Docker inside Docker), so root in
  the test machine is close to root on your computer. Don't publish the ports on a network.
- Even on `127.0.0.1`, other users of the same computer can reach the API, and so can, in
  principle, a web page you open while it runs. Run `docker compose down` when you're not using
  it, and don't run this on a shared machine.
- Only point `example.sh` and your own scripts at machines you are allowed to test.

## License

MIT, see [LICENSE](LICENSE).
