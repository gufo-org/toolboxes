# Systemd Integration for Gufo Server

You can run `gufo serve` as a background systemd user service via Podman.

---

## 1. Directory Setup

Create the local models folder on your host:

```bash
mkdir -p ~/.local/share/gufo/models
```

Place your model GGUF file inside:
```bash
cp /path/to/my-model.gguf ~/.local/share/gufo/models/model.gguf
```

---

## 2. Installing the Service

Copy the systemd service file into your user services directory:

```bash
mkdir -p ~/.config/systemd/user/
cp systemd/gufo-serve.service ~/.config/systemd/user/
```

Reload the systemd user daemon:
```bash
systemctl --user daemon-reload
```

---

## 3. Managing the Service

```bash
# Start the server
systemctl --user start gufo-serve

# Enable on boot (persistent login session)
systemctl --user enable gufo-serve
loginctl enable-linger $USER

# Check status and logs
systemctl --user status gufo-serve
journalctl --user -u gufo-serve -f

# Stop the server
systemctl --user stop gufo-serve
```

The server will be reachable on `http://127.0.0.1:8080`.
