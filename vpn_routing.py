#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from ipaddress import ip_network
from pathlib import Path


@dataclass(frozen=True)
class ServerDefinition:
    name: str
    gateway: str | None
    networks: tuple[str, ...]


@dataclass(frozen=True)
class Route:
    network: str
    gateway: str
    interface: str | None = None

    def to_command(self) -> str:
        command = f"ip route replace {self.network} via {self.gateway}"
        if self.interface:
            command = f"{command} dev {self.interface}"
        return command


def load_topology(path: str | Path) -> tuple[ServerDefinition, ...]:
    data = json.loads(Path(path).read_text())
    return tuple(
        ServerDefinition(
            name=server["name"],
            gateway=server.get("gateway"),
            networks=tuple(server.get("networks", ())),
        )
        for server in data["servers"]
    )


def build_routes(
    servers: tuple[ServerDefinition, ...], source_server: str, interface: str | None = None
) -> tuple[Route, ...]:
    server_names = {server.name for server in servers}
    if source_server not in server_names:
        raise ValueError(f"Unknown server '{source_server}'.")

    advertised_networks: dict[str, str] = {}
    routes: list[Route] = []
    for server in servers:
        if server.name == source_server:
            continue
        if server.networks and not server.gateway:
            raise ValueError(f"Server '{server.name}' is missing a gateway.")
        for network in server.networks:
            normalized_network = str(ip_network(network, strict=False))
            previous_server = advertised_networks.get(normalized_network)
            if previous_server and previous_server != server.name:
                raise ValueError(
                    f"Network '{normalized_network}' is advertised by both "
                    f"'{previous_server}' and '{server.name}'."
                )
            advertised_networks[normalized_network] = server.name
            routes.append(
                Route(
                    network=normalized_network,
                    gateway=server.gateway,
                    interface=interface,
                )
            )
    return tuple(routes)


def render_route_commands(
    servers: tuple[ServerDefinition, ...], source_server: str, interface: str | None = None
) -> tuple[str, ...]:
    return tuple(route.to_command() for route in build_routes(servers, source_server, interface))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate route commands for networks behind other VPN servers."
    )
    parser.add_argument("topology", help="Path to a JSON file that defines the VPN topology.")
    parser.add_argument(
        "--server", required=True, help="The server name to generate routes for."
    )
    parser.add_argument("--interface", help="Optional network interface to pin each route to.")
    args = parser.parse_args(argv)

    servers = load_topology(args.topology)
    for command in render_route_commands(servers, args.server, args.interface):
        print(command)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
