"""Generate a geo-referenced SUMO corridor (nodes, edges, traffic lights, routes) from corridor.json.

Junction ids equal the backend intersection codes (I1, I2, ...), so the bridge maps them
directly. Node coordinates are given in lon/lat and projected to UTM by netconvert, which
keeps the geo-reference in the .net.xml (traci.simulation.convertGeo then returns lon/lat).

Usage: uv run python build_network.py [network/corridor.json]
"""
import json
import math
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent / "network"


def offset(lat: float, lon: float, bearing: float, metres: float) -> tuple[float, float]:
    r = 6371008.8
    b = math.radians(bearing)
    dlat = metres * math.cos(b) / r
    dlon = metres * math.sin(b) / (r * math.cos(math.radians(lat)))
    return lat + math.degrees(dlat), lon + math.degrees(dlon)


def netconvert() -> str:
    try:
        import sumo  # eclipse-sumo wheel

        return str(Path(sumo.SUMO_HOME) / "bin" / "netconvert")
    except ImportError:
        return "netconvert"


def main() -> None:
    spec = json.loads(Path(sys.argv[1] if len(sys.argv) > 1 else HERE / "corridor.json").read_text())
    nodes = spec["intersections"]
    arm = spec["arm_length_m"]
    speed = spec["speed_mps"]
    nod, edg = ['<nodes>'], ['<edges>']
    for n in nodes:
        nod.append(f'  <node id="{n["code"]}" x="{n["lon"]:.7f}" y="{n["lat"]:.7f}" type="traffic_light" tl="{n["code"]}"/>')
        for name, bearing in (("N", 0), ("S", 180)):
            lat, lon = offset(n["lat"], n["lon"], bearing, arm)
            nod.append(f'  <node id="{n["code"]}_{name}" x="{lon:.7f}" y="{lat:.7f}" type="priority"/>')
            edg.append(f'  <edge id="{n["code"]}_{name}_in" from="{n["code"]}_{name}" to="{n["code"]}" numLanes="1" speed="{speed}"/>')
            edg.append(f'  <edge id="{n["code"]}_{name}_out" from="{n["code"]}" to="{n["code"]}_{name}" numLanes="1" speed="{speed}"/>')
    first, last = nodes[0], nodes[-1]
    lat, lon = offset(first["lat"], first["lon"], 270, arm)
    nod.append(f'  <node id="W_END" x="{lon:.7f}" y="{lat:.7f}" type="priority"/>')
    lat, lon = offset(last["lat"], last["lon"], 90, arm)
    nod.append(f'  <node id="E_END" x="{lon:.7f}" y="{lat:.7f}" type="priority"/>')
    edg.append(f'  <edge id="W_in" from="W_END" to="{first["code"]}" numLanes="2" speed="{speed}"/>')
    edg.append(f'  <edge id="W_out" from="{first["code"]}" to="W_END" numLanes="2" speed="{speed}"/>')
    edg.append(f'  <edge id="E_in" from="E_END" to="{last["code"]}" numLanes="2" speed="{speed}"/>')
    edg.append(f'  <edge id="E_out" from="{last["code"]}" to="E_END" numLanes="2" speed="{speed}"/>')
    for a, b in zip(nodes, nodes[1:]):
        edg.append(f'  <edge id="{a["code"]}_{b["code"]}" from="{a["code"]}" to="{b["code"]}" numLanes="2" speed="{speed}"/>')
        edg.append(f'  <edge id="{b["code"]}_{a["code"]}" from="{b["code"]}" to="{a["code"]}" numLanes="2" speed="{speed}"/>')
    nod.append('</nodes>')
    edg.append('</edges>')
    (HERE / "corridor.nod.xml").write_text("\n".join(nod) + "\n")
    (HERE / "corridor.edg.xml").write_text("\n".join(edg) + "\n")
    subprocess.run([netconvert(), "--node-files", str(HERE / "corridor.nod.xml"), "--edge-files", str(HERE / "corridor.edg.xml"),
                    "--proj.utm", "true", "--output-file", str(HERE / "corridor.net.xml"), "--no-turnarounds", "true",
                    "--tls.default-type", "static"], check=True)

    # Routes: main road both ways, side streets crossing, and a periodic ambulance.
    main, side = spec["flows_veh_per_hour"]["main"], spec["flows_veh_per_hour"]["side"]
    corridor_e = ["W_in"] + [f'{a["code"]}_{b["code"]}' for a, b in zip(nodes, nodes[1:])] + ["E_out"]
    corridor_w = ["E_in"] + [f'{b["code"]}_{a["code"]}' for a, b in reversed(list(zip(nodes, nodes[1:])))] + ["W_out"]
    rou = ['<routes>',
           '  <vType id="car" vClass="passenger" accel="2.0" decel="4.5" sigma="0.5" length="4.5" maxSpeed="16"/>',
           '  <vType id="ambulance" vClass="emergency" guiShape="emergency" color="1,0,0" accel="2.6" decel="5" length="6" maxSpeed="20" speedFactor="1.3"/>',
           f'  <route id="east" edges="{" ".join(corridor_e)}"/>',
           f'  <route id="west" edges="{" ".join(corridor_w)}"/>']
    for n in nodes:
        rou.append(f'  <route id="{n["code"]}_ns" edges="{n["code"]}_N_in {n["code"]}_S_out"/>')
        rou.append(f'  <route id="{n["code"]}_sn" edges="{n["code"]}_S_in {n["code"]}_N_out"/>')
    rou.append(f'  <flow id="east" type="car" route="east" begin="0" end="86400" vehsPerHour="{main}" departLane="best"/>')
    rou.append(f'  <flow id="west" type="car" route="west" begin="0" end="86400" vehsPerHour="{main}" departLane="best"/>')
    for n in nodes:
        rou.append(f'  <flow id="{n["code"]}_ns" type="car" route="{n["code"]}_ns" begin="0" end="86400" vehsPerHour="{side}"/>')
        rou.append(f'  <flow id="{n["code"]}_sn" type="car" route="{n["code"]}_sn" begin="0" end="86400" vehsPerHour="{side}"/>')
    rou.append(f'  <flow id="ambulance" type="ambulance" route="east" begin="60" end="86400" period="{spec["emergency_every_s"]}"/>')
    rou.append('</routes>')
    (HERE / "corridor.rou.xml").write_text("\n".join(rou) + "\n")
    (HERE / "corridor.sumocfg").write_text(
        '<configuration>\n  <input>\n    <net-file value="corridor.net.xml"/>\n    <route-files value="corridor.rou.xml"/>\n'
        '  </input>\n  <time>\n    <begin value="0"/>\n    <step-length value="1"/>\n  </time>\n</configuration>\n')
    print(f"Wrote network for {len(nodes)} intersections to {HERE}")


if __name__ == "__main__":
    main()
