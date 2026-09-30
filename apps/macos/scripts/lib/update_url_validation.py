#!/usr/bin/python3
import ipaddress
import sys
from urllib.parse import urljoin, urlsplit


def parse(candidate: str):
    if not candidate or any(ord(character) <= 32 or ord(character) == 127 for character in candidate):
        raise ValueError("URL contains whitespace or control characters")
    parsed = urlsplit(candidate)
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("URL credentials are forbidden")
    if parsed.fragment:
        raise ValueError("URL fragments are forbidden")
    if not parsed.hostname:
        raise ValueError("URL hostname is required")
    try:
        port = parsed.port
    except ValueError as error:
        raise ValueError("URL port is invalid") from error
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("URL port is invalid")
    return parsed


def validate(mode: str, candidate: str):
    parsed = parse(candidate)
    if mode == "production":
        if parsed.scheme.lower() != "https":
            raise ValueError("production URL must use HTTPS")
    elif mode == "fixture":
        if parsed.scheme.lower() not in {"http", "https"}:
            raise ValueError("fixture URL must use HTTP or HTTPS")
        hostname = parsed.hostname.lower()
        if hostname != "localhost":
            try:
                if ipaddress.ip_address(hostname) not in {
                    ipaddress.ip_address("127.0.0.1"),
                    ipaddress.ip_address("::1"),
                }:
                    raise ValueError("fixture URL must use loopback")
            except ValueError as error:
                raise ValueError("fixture URL must use loopback") from error
    else:
        raise ValueError("unknown validation mode")


def main():
    if len(sys.argv) != 3:
        return 64
    mode, candidate = sys.argv[1:]
    try:
        if mode == "parent":
            parsed = parse(candidate)
            if parsed.scheme.lower() != "https":
                raise ValueError("production URL must use HTTPS")
            print(urljoin(candidate, "."))
        else:
            validate(mode, candidate)
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
