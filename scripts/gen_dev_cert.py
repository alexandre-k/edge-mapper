#!/usr/bin/env python3
"""Generate a local HTTPS leaf server certificate for localhost / 127.0.0.1
and optionally serve a static directory (e.g. build/web) over HTTPS."""

import argparse
import datetime
import functools
import http.server
import ipaddress
import os
import ssl
import sys
from pathlib import Path


class _HardenedStaticHandler(http.server.SimpleHTTPRequestHandler):
    """Static file handler that disables directory listings and sets basic security headers."""

    def list_directory(self, path):  # noqa: ARG002
        self.send_error(403, "Directory listing is disabled")
        return None

    def end_headers(self) -> None:
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        super().end_headers()


def generate_cert(cert_path: Path, key_path: Path, host: str = "localhost") -> None:
    try:
        from cryptography import x509
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
    except ImportError:
        sys.stderr.write(
            "Python 'cryptography' package not found. Install it or install mkcert/openssl.\n"
        )
        sys.exit(1)

    cert_path.parent.mkdir(parents=True, exist_ok=True)
    key_path.parent.mkdir(parents=True, exist_ok=True)

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    subject = issuer = x509.Name(
        [
            x509.NameAttribute(NameOID.COMMON_NAME, "Edge Mapper Local Dev"),
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Edge Mapper Dev"),
        ]
    )

    now = datetime.datetime.now(datetime.timezone.utc)
    san_entries: list[x509.GeneralName] = [
        x509.DNSName("localhost"),
        x509.IPAddress(ipaddress.IPv4Address("127.0.0.1")),
        x509.IPAddress(ipaddress.IPv6Address("::1")),
    ]
    if host not in ("localhost", "127.0.0.1", "::1"):
        try:
            san_entries.append(x509.IPAddress(ipaddress.ip_address(host)))
        except ValueError:
            san_entries.append(x509.DNSName(host))

    # Generate a non-CA leaf server certificate (CA:FALSE, short 90-day validity)
    # so trusting it locally can NEVER mint certificates for arbitrary domains.
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=90))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=True,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),
            critical=False,
        )
        .add_extension(x509.SubjectAlternativeName(san_entries), critical=False)
        .sign(key, hashes.SHA256())
    )

    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    )
    # Write private key atomically with 0600 permissions (no TOCTOU race).
    fd = os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(key_pem)
    os.chmod(key_path, 0o600)


def serve_https(directory: Path, cert_path: Path, key_path: Path, host: str, port: int) -> None:
    if not directory.is_dir():
        sys.stderr.write(
            f"Directory '{directory}' does not exist. Run './flutter/bin/flutter build web' first.\n"
        )
        sys.exit(1)

    handler = functools.partial(
        _HardenedStaticHandler,
        directory=str(directory),
    )
    server = http.server.ThreadingHTTPServer((host, port), handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile=str(cert_path), keyfile=str(key_path))
    server.socket = context.wrap_socket(server.socket, server_side=True)

    print(f"Serving '{directory}' over HTTPS at https://{host}:{port}")
    print(f"OSM OAuth 2.0 Redirect URI: https://{host}:{port}/osm_callback.html")
    print("Press Ctrl+C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped HTTPS server.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Edge Mapper local HTTPS helper")
    parser.add_argument("--cert", type=Path, required=True, help="Output PEM cert path")
    parser.add_argument("--key", type=Path, required=True, help="Output PEM key path")
    parser.add_argument("--host", default="localhost", help="Hostname (default: localhost)")
    parser.add_argument("--port", type=int, default=8443, help="HTTPS port (default: 8443)")
    parser.add_argument("--force", action="store_true", help="Regenerate cert even if present")
    parser.add_argument(
        "--serve-dir",
        type=Path,
        default=None,
        help="If set, serve this directory over HTTPS after ensuring certs exist",
    )
    args = parser.parse_args()

    if args.force or not (args.cert.is_file() and args.key.is_file()):
        generate_cert(args.cert, args.key, host=args.host)
        print(f"Generated dev TLS leaf certificate: {args.cert}")

    if args.serve_dir is not None:
        serve_https(args.serve_dir, args.cert, args.key, args.host, args.port)


if __name__ == "__main__":
    main()
