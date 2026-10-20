# Computer Security Project: test machines

Two identical, throwaway **Debian 13** machines (Docker containers) on your own computer, for
testing scripts before running them anywhere else. Each one has:

- root SSH login by password, and
- the Docker Engine API on port 2375 over plain HTTP with no authentication (a common
  misconfiguration, so you can practise talking to a remote Docker API).

Both machines run the same stock image, so they should answer every check the same way. A
difference between them is noise, which is useful for learning what noise looks like.

## Start

Needs Docker with Compose (Linux, or Docker Desktop on macOS/Windows).

```bash
cp .env.example .env        # set ROOT_PASSWORD to something of your own
docker compose up -d --build
docker compose logs -f      # wait for "test machine ready" twice
```

| | SSH | Docker API |
|---|---|---|
| target A | `ssh -p 2221 root@127.0.0.1` | `http://127.0.0.1:23751` |
| target B | `ssh -p 2222 root@127.0.0.1` | `http://127.0.0.1:23752` |

Stop with `docker compose down`; `docker compose down -v` also wipes their inner Docker data.

## Try it

```bash
# Docker API by hand
curl -s http://127.0.0.1:23751/version
curl -s http://127.0.0.1:23751/containers/json
DOCKER_HOST=tcp://127.0.0.1:23751 docker run --rm hello-world   # docker CLI against the API

# The same check on both machines, logged with UTC times to evidence.log
scripts/compare.sh ssh 'uname -a'
scripts/compare.sh api /info

# Timing: 10 runs per machine, 3 s apart, every number reported
scripts/compare.sh time ssh 'ls /usr/bin | wc -l' 10

# Record a whole terminal session as plain text
script -q session.log
```

`compare.sh` reads its targets from `A_HOST`, `A_SSH`, `A_API`, `B_HOST`, `B_SSH` and `B_API`;
the defaults are the two local test machines.

After `docker compose down` and a fresh `up`, the machines get new SSH host keys and SSH warns
that the key changed. That's expected. Clear the old keys with `ssh-keygen -R '[127.0.0.1]:2221'`
and `ssh-keygen -R '[127.0.0.1]:2222'`, or keep them apart with
`SSH_OPTS="-o UserKnownHostsFile=$HOME/.ssh/test_known_hosts"`.

## Safety

- The ports are bound to `127.0.0.1` on purpose. An open Docker API is root on whatever can
  reach it, and these containers run `--privileged` (needed for Docker inside Docker), so root
  in a test machine is close to root on your computer. Don't publish the ports on a network.
- Even on `127.0.0.1`, other users of the same computer can reach the API, and so can, in
  principle, a web page you open while it runs. Run `docker compose down` when you're not using
  it, and don't run this on a shared machine.
- Only point `compare.sh` and your own scripts at machines you are allowed to test.

## License

MIT, see [LICENSE](LICENSE).
