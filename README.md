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

# Record a whole terminal session as plain text
script -q session.log
```

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
