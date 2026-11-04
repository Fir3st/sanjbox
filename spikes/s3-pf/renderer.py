#!/usr/bin/python3
"""Render a bounded transparent-path laboratory hypothesis to stdout; never invokes PF."""
import argparse
import ipaddress
from pathlib import Path
import re
import sys


def render(family, uid, address, target_port, gateway_port, run_id):
    if type(uid) is not int or not 400 <= uid <= 60000:
        raise ValueError("UID range")
    if any(type(port) is not int or not 1024 <= port <= 65535 for port in (target_port, gateway_port)):
        raise ValueError("unprivileged port range")
    if not re.fullmatch(r"[a-z0-9]{8,12}", run_id):
        raise ValueError("run ID")
    ip = ipaddress.ip_address(address)
    if family not in (4, 6) or ip.version != family or ip.is_multicast or ip.is_unspecified or ip.is_loopback or getattr(ip, "scope_id", None):
        raise ValueError("single unicast non-loopback literal of requested family required")
    path = Path(__file__).parent / f"templates/transparent-v{family}.pf.in"
    result = path.read_text()
    values = {"UID": str(uid), f"TARGET_V{family}": str(ip), "TARGET_PORT": str(target_port), "GATEWAY_PORT": str(gateway_port), "TAG": f"C1_{run_id}_{uid}"}
    for key, value in values.items():
        result = result.replace(f"@{key}@", value)
    if re.search(r"@[A-Z_0-9]+@", result):
        raise ValueError("unresolved template placeholder")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--family", type=int, choices=(4, 6), required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--target-port", type=int, required=True)
    parser.add_argument("--gateway-port", type=int, required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    try:
        print(render(args.family, args.uid, args.target, args.target_port, args.gateway_port, args.run_id), end="")
    except ValueError as error:
        print(error, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
