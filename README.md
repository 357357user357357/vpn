# vpn

Small utility for generating routes to networks behind other VPN servers.

## Usage

Create a topology file:

```json
{
  "servers": [
    { "name": "server-a", "networks": ["10.0.0.0/24"] },
    { "name": "server-b", "gateway": "10.255.0.2", "networks": ["10.1.0.0/24"] }
  ]
}
```

Then generate route commands for the local server:

```bash
python /home/runner/work/vpn/vpn/vpn_routing.py topology.json --server server-a --interface wg0
```