import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from vpn_routing import ServerDefinition, build_routes, main, render_route_commands


class BuildRoutesTest(unittest.TestCase):
    def test_builds_routes_for_other_servers(self) -> None:
        servers = (
            ServerDefinition("server-a", None, ("10.0.0.0/24",)),
            ServerDefinition("server-b", "10.255.0.2", ("10.1.0.0/24",)),
            ServerDefinition("server-c", "10.255.0.3", ("10.2.0.0/24",)),
        )

        commands = render_route_commands(servers, "server-a", "wg0")

        self.assertEqual(
            commands,
            (
                "ip route replace 10.1.0.0/24 via 10.255.0.2 dev wg0",
                "ip route replace 10.2.0.0/24 via 10.255.0.3 dev wg0",
            ),
        )

    def test_requires_gateway_for_remote_networks(self) -> None:
        servers = (
            ServerDefinition("server-a", None, ("10.0.0.0/24",)),
            ServerDefinition("server-b", None, ("10.1.0.0/24",)),
        )

        with self.assertRaisesRegex(ValueError, "missing a gateway"):
            build_routes(servers, "server-a")

    def test_rejects_duplicate_network_advertisements(self) -> None:
        servers = (
            ServerDefinition("server-a", None, ("10.0.0.0/24",)),
            ServerDefinition("server-b", "10.255.0.2", ("10.1.0.0/24",)),
            ServerDefinition("server-c", "10.255.0.3", ("10.1.0.0/24",)),
        )

        with self.assertRaisesRegex(ValueError, "advertised by both"):
            build_routes(servers, "server-a")

    def test_cli_prints_commands(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            topology = Path(directory) / "topology.json"
            topology.write_text(
                json.dumps(
                    {
                        "servers": [
                            {"name": "server-a", "networks": ["10.0.0.0/24"]},
                            {
                                "name": "server-b",
                                "gateway": "10.255.0.2",
                                "networks": ["10.1.0.1/24"],
                            },
                        ]
                    }
                )
            )

            output = io.StringIO()
            with redirect_stdout(output):
                result = main([str(topology), "--server", "server-a", "--interface", "wg0"])

        self.assertEqual(result, 0)
        self.assertEqual(
            output.getvalue().strip(), "ip route replace 10.1.0.0/24 via 10.255.0.2 dev wg0"
        )


if __name__ == "__main__":
    unittest.main()
