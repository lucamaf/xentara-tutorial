# Xentara quickstart on RHEL 10

Run the example model (`model.json`, six synthetic signals printed to the terminal) on Red Hat Enterprise Linux 10 in about 15 minutes.

> **Unofficial setup.** Xentara is only published as Debian packages. `xentara-installer-rpm.sh` downloads them, verifies their signatures and converts them to RPMs on your machine. embedded ocean GmbH does not officially support this on RHEL (see the prompt the installer shows). Everything marked **docs** comes from https://docs.xentara.io/xentara/ (v2.1.1); everything marked **verified** was checked on a RHEL 10.3 VM.

**You need:** RHEL 10 (x86_64), a user with `sudo`, internet access, a Xentara licence (evaluation licences are free, see step 2), and this folder (`xentara-installer-rpm.sh`, `model.json`).

---

## 1. Install Xentara

```bash
chmod +x xentara-installer-rpm.sh
./xentara-installer-rpm.sh
```

What happens:

1. It checks the system libraries Xentara needs (glibc 2.36+ etc.), then asks you to confirm that you understand this is not an officially supported installation.
2. It installs `podman` if needed, and builds a small Debian 12 container used only to convert the packages.
3. It downloads the Xentara packages, verifies the signed repository metadata and each package's SHA256, converts them and installs them with `dnf`.
4. It sets up what the Debian packages' install scripts would have done: the library path (`/etc/ld.so.conf.d/xentara.conf`), the `realtime` group, and a systemd/udev reload.
5. It lets you pick additional skills (plugins). Skills that depend on Debian's libcurl are hidden because they cannot work on RHEL.

Check it:

```bash
xentara --version        # Xentara version 2.1.1   (verified)
```

Run the installer again later to add more skills.

## 2. Install a licence

Xentara will not run without a valid licence (**docs**).

**Evaluation licence:** run `xentara` once and open the trial-licence link it prints, or generate a licence ID and request a trial at https://try.xentara.io:

```bash
xentara-licence-id
```

**Install it:** put *all* licence files (the common licence file plus your node licence file) together into **one** of these directories, searched in this order (**docs**):

1. `~/.local/share/xentara/licence`
2. `/usr/local/share/xentara/licence`
3. `/usr/share/xentara/licence`

```bash
sudo mkdir -p /usr/local/share/xentara/licence
sudo cp licence.json /usr/local/share/xentara/licence/     # your licence file(s)
```

> Xentara uses the **first** licence it finds, valid or not. Don't leave an old or expired licence in an earlier directory. (**docs**)

## 3. Install the model

The default model file is `~/.config/xentara/model.json` (then `/etc/xdg/xentara/model.json`) (**docs**):

```bash
mkdir -p ~/.config/xentara
cp model.json ~/.config/xentara/model.json
```

What the example model does:

| Element | Purpose |
|---|---|
| `Sampler` (signal generator skill) | Generates 6 signals: pulse, sine, triangle, saw-tooth, inverted saw-tooth, noise |
| `Signals` group, 6 data points | Each data point's `io` points at one generated signal, e.g. `Sampler.Sine Wave` |
| `Sampler Track` → `Timer` (500 ms) → `Pipeline` | Every 500 ms the pipeline runs `Sampler.generate`, then `Inspector.dump` |
| `Inspector` (debugging skill) | Prints value, quality and timestamps of every signal to the terminal |

Validate it against the official schema (installed with Xentara; **verified**):

```bash
python3 -m json.tool ~/.config/xentara/model.json > /dev/null && echo "valid JSON"
ls /usr/share/xentara/json/schema-xentara-model.json
```

In an editor, the `"$schema"` line at the top of the model already points at the schema, so VS Code shows validation errors and completion.

## 4. Run it in the foreground

```bash
xentara
```

The inspector prints the generated signals every 500 ms. Stop with `Ctrl+C`.

To use a model from another location: `xentara --model=/path/to/model.json`. All options: `--help`, `--version`, `--config-dir`, `--model`, `--config`, `--plugin`, `--plugin-dir`, and files for security/users/passwords (**docs**).

## 5. Look inside a running Xentara

In a second terminal:

```bash
xentara-debugger
```

A terminal application that connects to the Xentara instance on the same computer (**docs**). You can explore the model tree, read and write data points and attributes, suspend/resume and shut down Xentara. Type `help` for the commands. It connects to instances running as the same user; only `root` can connect to another user's instance.

## 6. Run it as a service

The package ships a template unit, `xentara@.service`; the part after `@` is the Linux user that Xentara runs as. The model is read from that user's `~/.config/xentara/` (**docs**, unit verified):

```bash
sudo systemctl enable --now xentara@$USER
systemctl status xentara@$USER
journalctl --unit=xentara@$USER --follow
```

Only `root` and that user can read the logs.

> **The name after `@` must be a real Linux user.** `$USER` expands to your login name (e.g. `xentara@admin`)

**The `realtime` group is required.** The unit contains `SupplementaryGroups=realtime`. If the group doesn't exist, systemd refuses to start the service with `status=216/GROUP` (**verified** on the VM). The installer creates it. If you installed another way:

```bash
sudo groupadd --system realtime
```

You do **not** need to add your user to `realtime` for the systemd service (**docs**: privileges are granted automatically). Only when you start `xentara` by hand and want real-time scheduling do you need `sudo usermod --append --groups realtime $USER`, followed by logging out and in again.

## 7. Optional tuning

| Topic | RHEL 10 notes |
|---|---|
| **Time synchronisation** | Xentara recommends `chrony` instead of `systemd-timesyncd` (**docs**). RHEL already uses `chronyd`, and it was active on the VM (**verified**). Check with `chronyc tracking`. |
| **Real-time kernel** | Real-time tasks need a `PREEMPT_RT` kernel (**docs**). On RHEL that is the `kernel-rt` package from the "RHEL for Real Time" repository, which needs the matching subscription. Check with `uname -v`. The example model doesn't need it. |
| **Core isolation** | Docs example: `isolcpus=14,15 rcu_nocbs=14,15 rcu_nocb_poll` on the kernel command line (**docs**, uses Debian's `update-grub`). On RHEL: `sudo grubby --update-kernel=ALL --args="isolcpus=14,15 rcu_nocbs=14,15 rcu_nocb_poll"`, then reboot. *(RHEL command not tested here.)* |

## 8. Xentara Inspector (web UI)

The Inspector ([quick start guide](https://kb.xentara.io/articles/xentara-inspector-v1-quick-start-guide), needs Xentara 2.1+) is a web page that talks to Xentara's WebSocket interface on port **19670** (HTTPS, self-signed certificate). It also needs a Xentara user with a password. **Xentara does not open port 19670 on its own**: with no `config.json`, the built-in HTTP server is off. This was **verified** on the VM (`ss -tlnp` showed no listener on 19670, and no `config.json` existed).

The knowledge-base article is written for Ubuntu and Docker. On RHEL 10 the differences are `firewalld` instead of `ufw`, `podman` instead of Docker, and the config key is `portNumber` (the article says `port`; the installed schema says `portNumber`).

**1. Enable the HTTP/WebSocket server.** Create `~/.config/xentara/config.json` (of the user the service runs as):

```json
{
  "$schema": "https://docs.xentara.io/xentara/schema-xentara-config.json",
  "httpServer": {
    "services": ["WebSocket"],
    "portNumber": 19670,
    "authentication": { "schemes": ["Bearer", "Basic"] },
    "CORS": {
      "allowedOrigins": [
        "http://192.168.122.9:8090",
        "https://192.168.122.9:8090",
        "http://localhost:8090",
        "https://localhost:8090"
      ]
    }
  }
}
```

Two settings matter here, and both were needed on the test VM (**verified**: the Inspector login works with this configuration):

- **`CORS.allowedOrigins`** must contain the exact origin (`scheme://host:port`, no trailing slash) of the address in the browser's URL bar. The browser loads the page from port 8090 and then connects to port 19670. `http://` and `https://` are different origins, and so are the IP address and `localhost`. Use your machine's address instead of `192.168.122.9`.
- **`authentication.schemes`** must include `Basic`. By default the server only offers `Bearer` (`WWW-Authenticate: Bearer realm="Xentara"`), and the Inspector's username/password login is then refused with 401.

**1b. Create a TLS certificate.** The HTTP server only speaks HTTPS and Xentara does not create a certificate itself. Without one, Xentara stops at start-up with `FATAL ERROR: HTTP server: could not find the TLS certificate file at ".../certs/xentara.pem"` (**verified** on the VM). It looks for the certificate and key in these places (**docs**), which must share the same base directory:

- `~/.config/xentara/certs/xentara.pem`, then `/etc/xdg/xentara/certs/xentara.pem`
- `~/.config/xentara/private/xentara.key.pem`, then `/etc/xdg/xentara/private/xentara.key.pem`

Create a self-signed certificate. Browsers reject a certificate for an IP address unless the address is in `subjectAltName`, so list every address or name you will use:

```bash
mkdir -p ~/.config/xentara/certs ~/.config/xentara/private
openssl req -nodes -x509 -newkey rsa:4096 -sha256 -days 3650 \
  -subj "/CN=xentara" \
  -addext "subjectAltName=IP:192.168.122.9,DNS:localhost" \
  -keyout ~/.config/xentara/private/xentara.key.pem \
  -out    ~/.config/xentara/certs/xentara.pem
chmod 0600 ~/.config/xentara/private/xentara.key.pem
```

(The key must not be readable by anyone but its owner. To use other paths, set `TLS.serverCertificate.certificatePath` and `privateKeyPath` in `security.json`.)

**2. Create a user and a password.** Both are case-sensitive. Create `~/.config/xentara/users.json` (generate a UUID with `uuidgen`):

```json
{
  "$schema": "https://docs.xentara.io/xentara/schema-xentara-users.json",
  "users": [ { "UUID": "<output of uuidgen>", "userName": "admin" } ]
}
```

Then set the password (it asks for it and stores it in the password file):

```bash
xentara-password admin
```

**2b. Allow writing (optional).** By default, remote clients (the Inspector, the dashboard in `xentara-lab/dashboard`) may only read: every write is refused with `access denied (-32102)` (**verified**). Give the user a role that may write. Create `~/.config/xentara/security.json`:

```json
{
  "roles": [ { "name": "Operator", "UUID": "<output of uuidgen>" } ],
  "ACL": { "entries": [ { "role": "Operator", "allow": ["write"] } ] }
}
```

and add the role to the user in `users.json`: `{ "UUID": "...", "userName": "admin", "roles": ["Operator"] }`. Everyone else stays read-only.

**3. Restart and check that it listens:**

```bash
sudo systemctl restart xentara@$USER
sudo ss -ltnp | grep :19670     # must show xentara
journalctl --unit=xentara@$USER --lines=30
```

**4. Open the firewall** (RHEL uses `firewalld`, not `ufw`), only if you open the Inspector from another computer:

```bash
sudo firewall-cmd --permanent --add-port=19670/tcp --add-port=8090/tcp
sudo firewall-cmd --reload
```

**5. Start the Inspector** with podman (the article uses Docker Compose):

```bash
podman run -d --replace --name xentara-inspector --restart unless-stopped -p 8090:8080 docker.io/xentara/xentara-inspector:1.0
curl -I http://localhost:8090      # expect HTTP/1.1 200 OK
```

**6. Open it** at `http://<machine address>:8090`. The first time, the page says "Could not connect to Xentara": open the certificate page it links to (https://<address>:19670), accept the self-signed certificate once, go back and click **Check Connection**, then log in.

Run the Inspector on the same machine as Xentara: it looks for Xentara on the host it was loaded from (**docs**).

## 9. Xentara Inspector (web UI)  

An example based on a water tank simulated model is avalailable in the folder `./xentara-lab`.  
The model is running as python code with modbus communication, Xentara model is leveraging the modbus plugin to connect to it and read/write to registries.  Additionally an HTML dashboard is present to visualize the model live (and can drive the model, writing registers through Xentara).  

![alt text](<Screenshot From 2026-11-25 14-44-51.png>)

![alt text](<Screenshot From 2026-11-25 14-45-05.png>)


## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `error while loading shared libraries: libxentara-plugin.so.2.1` | Debian's library directory isn't in the loader path. `echo /usr/lib/x86_64-linux-gnu \| sudo tee /etc/ld.so.conf.d/xentara.conf && sudo ldconfig` (the installer does this). |
| Service fails, `status=217/USER` | The instance name after `@` isn't an existing user (e.g. literal `xentara@USER`). Use `xentara@<your login name>`. |
| Service fails, `status=216/GROUP` | The `realtime` group is missing: `sudo groupadd --system realtime` |
| `nothing provides lib…so…` or "libraries … are not installed and are not available" | A skill needs a library that RHEL doesn't ship (e.g. `libonnxruntime.so.1` for the ONNX engine). Install the library yourself and re-run the installer. |
| Inspector: "Could not connect to Xentara", nothing on port 19670 | No `config.json` with `httpServer`, or Xentara was not restarted. See step 8. Check with `sudo ss -ltnp \| grep :19670`. |
| Xentara stops with `could not find the TLS certificate file` | Step 1b: create `~/.config/xentara/certs/xentara.pem` and `private/xentara.key.pem`. |
| Browser rejects the certificate for the IP address | The certificate has no `subjectAltName` for that address. Recreate it with `-addext "subjectAltName=IP:<address>,DNS:localhost"`. |
| Writing from the Inspector or the dashboard fails with `access denied (-32102)` | The role of the user has no `write` entitlement. See step 2b (security.json and the role in users.json), restart Xentara. |
| Inspector: login refused (401), CORS is fine | Only `Bearer` is enabled. Add `"authentication": { "schemes": ["Bearer", "Basic"] }` to `httpServer`, restart, and test with `curl -sk -u admin -X POST https://<address>:19670/api/v1/request-token`. |
| Inspector: CORS error at login | Add the exact origin from the error message (check `http` vs `https`, IP vs `localhost`) to `httpServer.CORS.allowedOrigins`, restart Xentara. |
| Skill missing from the list | Hidden on purpose: it needs Debian's libcurl, which isn't compatible. |
| Xentara exits at start, licence message | No valid licence in the first licence directory found. See step 2. |
| Suspected SELinux problem (RHEL enforces it) | `sudo ausearch -m avc -ts recent`. Don't disable SELinux; add a targeted policy if something is denied. *(Not seen on the test VM so far.)* |

## What has and hasn't been tested

- **Verified on RHEL 10.3:** installer, `xentara --version`, installed files and unit, the 216/GROUP failure without the `realtime` group, the 217/USER failure with a non-existent user, active `chronyd`, licence directory search path, Xentara running with the example model and a licence in `/usr/local/share/xentara/licence`, the **systemd service** (`xentara@admin`, active and printing the signals to the journal after creating the `realtime` group), and **`xentara-debugger`** connecting to a running instance.
- **Not yet confirmed:** that a fresh run of the updated installer creates the `realtime` group by itself (the VM's group was created by hand), the RHEL-specific real-time kernel and core-isolation notes in step 7.
