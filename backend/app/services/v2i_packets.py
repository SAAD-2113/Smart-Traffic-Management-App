"""Server-side checks of Digital V2I messages, with the limits of firmware v3 (v2i_common.h).

The relay forwards a packet's text unchanged, so the intersection phone parses exactly what the
vehicle sent, as the ESP32 would. These checks only decide whether a message may pass.
"""
import json
import math
from typing import Any

V2I_MAX_PACKET = 200  # every packet must be shorter than this (bytes, firmware buffer incl. terminator)
MAX_STATE_BYTES = 32 * 1024
LANES = ("N", "E", "S", "W")
STATES = ("APPROACHING", "QUEUED", "CROSSING", "IGNORED")
POS_KEYS = {"t", "id", "ty", "lat", "lon", "spd", "hdg", "seq", "hw", "tl", "rssi"}


class PacketError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


def _is_int(v: Any) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def _is_num(v: Any) -> bool:
    return (isinstance(v, (int, float)) and not isinstance(v, bool)) and math.isfinite(v)


def _object(raw: Any, limit: int) -> dict:
    if not isinstance(raw, str):
        raise PacketError("BAD_PACKET", "raw must be the packet text")
    if len(raw.encode("utf-8")) >= limit:
        raise PacketError("PACKET_TOO_LONG", f"packets must be shorter than {limit} bytes")
    try:
        d = json.loads(raw)
    except ValueError:
        raise PacketError("BAD_PACKET", "not JSON") from None
    if not isinstance(d, dict):
        raise PacketError("BAD_PACKET", "not a JSON object")
    return d


def validate_pos(raw: Any, vehicle_id: int, emergency_allowed: bool) -> dict:
    """A vehicle's "pos" packet. The id must be the account's own V2I id, and "ty":1 needs an
    approved emergency authorisation. Returns the parsed packet."""
    d = _object(raw, V2I_MAX_PACKET)
    if d.get("t") != "pos":
        raise PacketError("BAD_PACKET", '"t" must be "pos"')
    unknown = set(d) - POS_KEYS
    if unknown:
        raise PacketError("BAD_PACKET", f"unknown field {sorted(unknown)[0]}")
    if not _is_int(d.get("id")) or d["id"] != vehicle_id:
        raise PacketError("WRONG_VEHICLE_ID", "id must be this account's vehicle id")
    ty = d.get("ty", 0)
    if not _is_int(ty) or ty not in (0, 1):
        raise PacketError("BAD_PACKET", "ty must be 0 or 1")
    if ty == 1 and not emergency_allowed:
        raise PacketError("EMERGENCY_NOT_AUTHORIZED", "this account is not authorised as an emergency vehicle")
    lat, lon = d.get("lat"), d.get("lon")
    if not _is_num(lat) or not -90 <= lat <= 90 or not _is_num(lon) or not -180 <= lon <= 180:
        raise PacketError("BAD_PACKET", "lat/lon out of range")
    if "spd" in d and (not _is_num(d["spd"]) or not 0 <= d["spd"] <= 400):
        raise PacketError("BAD_PACKET", "spd must be 0..400 km/h")
    if "hdg" in d and (not _is_int(d["hdg"]) or not 0 <= d["hdg"] <= 359):
        raise PacketError("BAD_PACKET", "hdg must be an integer 0..359")
    if not _is_int(d.get("seq")) or not 0 <= d["seq"] <= 0xFFFFFFFF:
        raise PacketError("BAD_PACKET", "seq must be an unsigned integer")
    if "hw" in d and (not isinstance(d["hw"], str) or len(d["hw"]) > 11):
        raise PacketError("BAD_PACKET", "hw must be text of at most 11 characters")
    if "tl" in d and d["tl"] not in LANES:
        raise PacketError("BAD_PACKET", "tl must be N, E, S or W")
    if "rssi" in d and (not _is_int(d["rssi"]) or not -130 <= d["rssi"] <= 0):
        raise PacketError("BAD_PACKET", "rssi must be -130..0 dBm")
    return d


def validate_ack(raw: Any, to: Any) -> dict:
    """An intersection's ACK to vehicle [to] (layout of the firmware's snprintf)."""
    d = _object(raw, V2I_MAX_PACKET)
    if d.get("t") != "ack" or not _is_int(to) or d.get("id") != to:
        raise PacketError("BAD_PACKET", "an ACK must have t=ack and the id of its vehicle")
    if not _is_int(d.get("seq")) or d["seq"] < 0:
        raise PacketError("BAD_PACKET", "seq")
    if d.get("mode") not in ("fixed", "adaptive"):
        raise PacketError("BAD_PACKET", "mode")
    if d.get("lane") not in (*LANES, "-") or d.get("st") not in STATES or d.get("sig") not in ("G", "Y", "R", "-"):
        raise PacketError("BAD_PACKET", "lane / st / sig")
    if not _is_num(d.get("rem")) or not 0 <= d["rem"] <= 6000:
        raise PacketError("BAD_PACKET", "rem")
    if d.get("pri") not in (0, 1) or isinstance(d.get("pri"), bool):
        raise PacketError("BAD_PACKET", "pri")
    return d


def validate_state(raw: Any) -> dict:
    """The intersection's state JSON (firmware buildState(): "v":2 and "t":"state")."""
    d = _object(raw, MAX_STATE_BYTES)
    if d.get("v") != 2 or d.get("t") != "state":
        raise PacketError("BAD_STATE", 'state must have "v":2 and "t":"state"')
    return d
