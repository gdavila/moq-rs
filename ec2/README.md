# Running moq-rs on an EC2 / Ubuntu instance with valid TLS

This folder sets up an Ubuntu EC2 instance as a moq-rs **pub/relay** with a
browser-trusted TLS certificate, so MOQ/QUIC (WebTransport) playback works in
Chrome and with native clients.

## Why a DuckDNS domain (not the EC2 hostname)

Let's Encrypt **refuses to issue certificates for AWS-owned hostnames** such as
`ec2-…​.compute-1.amazonaws.com`. To get a valid cert you need a domain you
control. The scripts use a free [DuckDNS](https://www.duckdns.org) subdomain
with the DNS-01 challenge (no inbound port 80 required).

## Prerequisites (AWS side)

1. **Allocate an Elastic IP** and associate it with the instance (EC2 public IPs
   change on stop/start, which would invalidate your DNS record).
2. **Create a DuckDNS subdomain** (e.g. `moq-gabriel.duckdns.org`) and point it
   at your Elastic IP. Grab your account **token** from the DuckDNS page.
3. **Security Group inbound rules:**

   | Type       | Protocol | Port | Purpose                        |
   |------------|----------|------|--------------------------------|
   | Custom UDP | UDP      | 4443 | MOQ / QUIC (WebTransport)      |
   | Custom TCP | TCP      | 4443 | HTTP/3 fallback / fingerprint  |
   | SSH        | TCP      | 22   | your access                    |

   QUIC is **UDP** — the most common thing people forget.

## Quick start

```bash
git clone -b draft-ietf-moq-transport-14 https://github.com/cloudflare/moq-rs.git
cd moq-rs/ec2

cp config.example.sh config.sh
# edit config.sh: set DOMAIN, EMAIL, DUCKDNS_TOKEN

./setup.sh          # installs deps + Rust, issues the cert, builds moq-rs
```

Then run the relay and publisher:

```bash
./run-relay.sh                 # terminal 1 — starts the relay on :4443
./run-pub.sh                   # terminal 2 — publishes Big Buck Bunny as "bbb"
```

Test playback from your laptop (needs a local `moq-sub` build + `ffplay`):

```bash
moq-sub --name bbb 'https://<your-domain>.duckdns.org:4443' | ffplay -
```

Or in Chrome, point a draft-14 moq-js player at
`https://<your-domain>.duckdns.org:4443` (broadcast `bbb`, catalog `.catalog`).

## Scripts

| Script                | What it does                                                        |
|-----------------------|--------------------------------------------------------------------|
| `setup.sh`            | Runs everything below in order, then builds the moq-rs binaries.    |
| `01-install-deps.sh`  | apt build toolchain (`cmake`/`clang` for aws-lc-sys), ffmpeg, Rust. |
| `02-issue-cert.sh`    | Installs certbot + DuckDNS plugin and issues the cert via DNS-01.   |
| `03-setup-certs.sh`   | Copies PEMs to a user-readable dir; adds loopback `/etc/hosts`.     |
| `run-relay.sh`        | Starts the relay with the Let's Encrypt cert.                       |
| `run-pub.sh`          | Publishes the sample stream to the relay.                           |
| `renew-certs.sh`      | Renews the cert and refreshes the relay-readable copies.            |

All scripts read `config.sh` (git-ignored, so your token stays private).

## Certificate renewal

Let's Encrypt certificates last ~90 days. The relay reads copies of the PEMs
from `$CERT_DIR`, so after each renewal those copies must be refreshed and the
relay restarted. Either run `./renew-certs.sh` manually, or wire it as a certbot
deploy hook:

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/moq.sh >/dev/null <<'EOF'
#!/bin/bash
cp /etc/letsencrypt/live/DOMAIN/{fullchain.pem,privkey.pem} /home/ubuntu/moq-certs/
chown ubuntu:ubuntu /home/ubuntu/moq-certs/*.pem
chmod 600 /home/ubuntu/moq-certs/privkey.pem
# systemctl restart moq-relay   # if you run the relay as a service
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/moq.sh
```

## Gotchas we hit (and fixed)

- **QUIC is UDP** — open UDP 4443 in the Security Group, not just TCP.
- **Same-box publisher** connecting to the public domain can fail to hairpin
  over UDP. `03-setup-certs.sh` adds `127.0.0.1 <domain>` to `/etc/hosts` so the
  traffic stays local while the cert hostname still validates.
- **Start order matters:** relay → publisher → subscriber. The fMP4 init
  segment is published once (group 0) when the publisher's ffmpeg starts; a
  subscriber that joins a session without it gets media but no `moov`. Restart
  the subscriber whenever you restart the publisher.
- **`moq-sub` logs vs. media:** `moq-sub` writes media to stdout, so logs must
  go to stderr (fixed in this repo). If you use an older build, prefix commands
  with `RUST_LOG=off` before piping to `ffplay -`.
- **Video-only players:** the sample broadcast has both video and audio; make
  sure your player handles/subscribes to both tracks listed in the catalog.
