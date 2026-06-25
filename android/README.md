# Proxycept Android Demo (Kotlin + Compose)

A minimal Android sample that routes its HTTPS traffic through a **Proxycept** proxy and proves
the request was intercepted — it shows the response status, the captured body, and the **TLS
issuer** of the server certificate. When traffic is intercepted, the leaf cert for e.g.
`example.com` is signed by **`CN=Proxy Control CA`** (Proxycept's CA) instead of the real one.

![screenshot](docs/screenshot.png)

> The same request appears live in the Proxycept web app under **Sessions** as `GET 200 example.com/`.

## How it works

A standard `HttpsURLConnection` is opened through an HTTP `Proxy`. HTTPS is tunneled to the
proxy via `CONNECT`; the proxy terminates TLS with a cert minted by its CA, so the app must
**trust the Proxycept CA**. Trust is configured in `res/xml/network_security_config.xml`, which
adds the bundled CA (`res/raw/proxycept_ca.pem`) and user-installed CAs to the trust anchors:

```kotlin
val proxy = Proxy(Proxy.Type.HTTP, InetSocketAddress(host, port))
val conn = URL(target).openConnection(proxy) as HttpsURLConnection
conn.connect()
val issuer = (conn.serverCertificates.first() as X509Certificate).issuerX500Principal.name
// issuer contains "Proxy Control CA" when intercepted
```

**Emulator networking:** in the Android emulator, the host machine's loopback is **`10.0.2.2`**
(not `127.0.0.1`). On a physical device, use the host's LAN IP or the public edge host.

## Prerequisites

- A JDK 17 (`JAVA_HOME`), the Android SDK (`ANDROID_HOME`, platform 35 + build-tools), and a
  running emulator or device. (Android Studio provides all of these.)
- A running Proxycept with a **started proxy profile** — grab the proxy **host:port** and the
  **CA certificate** from the profile's *Connection* tab (or the API).

## Run it

```bash
# from examples/android-demo, with a booted emulator
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
export ANDROID_HOME=$HOME/Library/Android/sdk
PROXY_HOST=10.0.2.2 PROXY_PORT=19345 CA_PEM=/path/to/proxycept-ca.pem ./build-and-run.sh
```

Set the proxy host/port in the app's fields (defaults `10.0.2.2:19345`) or edit the constants
at the top of `MainActivity.kt`.

> **Replace the bundled CA.** `res/raw/proxycept_ca.pem` is an example CA — each Proxycept
> deployment has its own. Drop in your deployment's CA (or rely on `<certificates src="user"/>`
> and install the CA on the device).

## Files

- `app/src/main/java/com/proxycept/androiddemo/MainActivity.kt` — the whole app (Compose UI + proxied `HttpsURLConnection` + TLS-issuer probe).
- `app/src/main/res/xml/network_security_config.xml` — trust anchors (system + user + bundled CA).
- `build-and-run.sh` — build → install → launch on the connected device/emulator.
