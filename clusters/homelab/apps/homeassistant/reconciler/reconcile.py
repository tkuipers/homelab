#!/usr/bin/env python3
import asyncio
import json
import os
import sys
import urllib.error
import urllib.request
import yaml
import websockets

HA_URL = os.environ["HA_URL"]
HA_TOKEN = os.environ["HA_TOKEN"]
REGISTRY_PATH = os.environ.get("REGISTRY_PATH", "/registry/registry.yaml")

# Derive HTTP base URL from the WebSocket URL (ws://host:port/api/websocket -> http://host:port)
_HA_HTTP_BASE = HA_URL.replace("wss://", "https://").replace("ws://", "http://").removesuffix("/api/websocket")


def ha_http(method, path, body=None):
    url = f"{_HA_HTTP_BASE}{path}"
    headers = {"Authorization": f"Bearer {HA_TOKEN}", "Content-Type": "application/json"}
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} {method} {path}: {e.read().decode()}")


class HA:
    def __init__(self, ws):
        self.ws = ws
        self._id = 0

    async def call(self, msg):
        self._id += 1
        msg["id"] = self._id
        await self.ws.send(json.dumps(msg))
        while True:
            reply = json.loads(await self.ws.recv())
            if reply.get("id") == self._id and reply.get("type") == "result":
                if not reply.get("success"):
                    raise RuntimeError(f"HA call {msg['type']} failed: {reply.get('error')}")
                return reply.get("result")


async def connect_with_retry():
    for attempt in range(60):
        try:
            ws = await websockets.connect(HA_URL, open_timeout=5)
            hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
            if hello.get("type") != "auth_required":
                await ws.close()
                raise RuntimeError(f"unexpected handshake: {hello}")
            await ws.send(json.dumps({"type": "auth", "access_token": HA_TOKEN}))
            ack = json.loads(await asyncio.wait_for(ws.recv(), timeout=5))
            if ack.get("type") == "auth_ok":
                return ws
            await ws.close()
            raise RuntimeError(f"auth failed: {ack}")
        except (OSError, asyncio.TimeoutError) as e:
            if attempt % 6 == 0:
                print(f"Waiting for HA at {HA_URL}: {e}", flush=True)
            await asyncio.sleep(5)
    raise RuntimeError("HA not ready after 5 minutes")


async def reconcile_floors(ha, desired):
    existing = {f["name"]: f for f in await ha.call({"type": "config/floor_registry/list"})}
    for floor in desired:
        name = floor["name"]
        level = floor.get("level")
        icon = floor.get("icon")
        if name in existing:
            cur = existing[name]
            update = {}
            if level is not None and cur.get("level") != level:
                update["level"] = level
            if icon and cur.get("icon") != icon:
                update["icon"] = icon
            if update:
                print(f"floor update: {name} <- {update}", flush=True)
                await ha.call({"type": "config/floor_registry/update", "floor_id": cur["floor_id"], **update})
        else:
            print(f"floor create: {name}", flush=True)
            params = {"type": "config/floor_registry/create", "name": name}
            if level is not None:
                params["level"] = level
            if icon:
                params["icon"] = icon
            await ha.call(params)


async def reconcile_areas(ha, desired):
    floor_id_by_name = {f["name"]: f["floor_id"] for f in await ha.call({"type": "config/floor_registry/list"})}
    existing = {a["name"]: a for a in await ha.call({"type": "config/area_registry/list"})}
    for area in desired:
        name = area["name"]
        target_floor_id = floor_id_by_name.get(area["floor"]) if area.get("floor") else None
        icon = area.get("icon")
        if name in existing:
            cur = existing[name]
            update = {}
            if cur.get("floor_id") != target_floor_id:
                update["floor_id"] = target_floor_id
            if icon and cur.get("icon") != icon:
                update["icon"] = icon
            if update:
                print(f"area update: {name} <- {update}", flush=True)
                await ha.call({"type": "config/area_registry/update", "area_id": cur["area_id"], **update})
        else:
            print(f"area create: {name} (floor: {area.get('floor')})", flush=True)
            params = {"type": "config/area_registry/create", "name": name}
            if target_floor_id:
                params["floor_id"] = target_floor_id
            if icon:
                params["icon"] = icon
            await ha.call(params)


async def prune(ha, desired_floors, desired_areas):
    desired_area_names = {a["name"] for a in desired_areas}
    for area in await ha.call({"type": "config/area_registry/list"}):
        if area["name"] not in desired_area_names:
            print(f"area delete: {area['name']}", flush=True)
            await ha.call({"type": "config/area_registry/delete", "area_id": area["area_id"]})
    desired_floor_names = {f["name"] for f in desired_floors}
    for floor in await ha.call({"type": "config/floor_registry/list"}):
        if floor["name"] not in desired_floor_names:
            print(f"floor delete: {floor['name']}", flush=True)
            await ha.call({"type": "config/floor_registry/delete", "floor_id": floor["floor_id"]})


def _uid_role(uid):
    # matter uid: <fabric>-<compressed>-<node>-<endpoint>-<Cluster-attr-idx>
    p = (uid or "").split("-")
    return "-".join(p[4:]) if len(p) >= 5 else uid


def _uid_endpoint(uid):
    p = (uid or "").split("-")
    return int(p[3]) if len(p) >= 5 and p[3].isdigit() else 0


def _parse_role_key(key):
    # "MatterLight-6-0#1" -> ("MatterLight-6-0", 1); "PowerSource-47-12" -> (..., 0)
    if "#" in key:
        role, _, ordn = key.rpartition("#")
        return role, int(ordn)
    return key, 0


async def reconcile_matter_devices(ha, desired):
    """Match Matter devices by hardware serial (or, lacking one, by Matter identifier) and
    their entities by cluster role (+#ordinal for same-role endpoints). STRICT: any Matter
    device, or any entity on one, that isn't declared here is a fatal error — a paired device
    you forgot to add blocks the sync until it's declared. There is no rename-by-slug path."""
    specs = desired.get("matter_devices") or []
    area_id_by_name = {a["name"]: a["area_id"] for a in await ha.call({"type": "config/area_registry/list"})}
    dev_by_serial, dev_by_ident, matter_devices = {}, {}, {}
    for d in await ha.call({"type": "config/device_registry/list"}):
        is_matter = False
        for i in d.get("identifiers", []):
            if len(i) == 2:
                dev_by_ident[f"{i[0]}:{i[1]}"] = d
                if i[0] == "matter":
                    is_matter = True
        if d.get("serial_number"):
            dev_by_serial[d["serial_number"]] = d
        if is_matter:
            matter_devices[d["id"]] = d
    ents_by_device, existing_ids = {}, set()
    for e in await ha.call({"type": "config/entity_registry/list"}):
        existing_ids.add(e["entity_id"])
        if e.get("device_id"):
            ents_by_device.setdefault(e["device_id"], []).append(e)

    errors, claimed_device_ids = [], set()
    for spec in specs:
        if spec.get("serial") is not None:
            ref, d = f"serial {spec['serial']}", dev_by_serial.get(str(spec["serial"]))
        elif spec.get("identifier"):
            ref, d = f"identifier {spec['identifier']}", dev_by_ident.get(spec["identifier"])
        else:
            errors.append(f"matter_device with neither serial nor identifier: {spec!r}")
            continue
        if not d:
            errors.append(f"matter_device {ref}: not found in HA")
            continue
        claimed_device_ids.add(d["id"])

        area_name = spec.get("area")
        area_id = area_id_by_name.get(area_name) if area_name else None
        if area_name and area_id is None:
            errors.append(f"matter_device {ref}: area {area_name!r} not found")
            continue

        dev_ents = ents_by_device.get(d["id"], [])
        groups = {}
        for e in sorted(dev_ents, key=lambda e: _uid_endpoint(e.get("unique_id"))):
            groups.setdefault(_uid_role(e.get("unique_id")), []).append(e)

        matched = set()
        for key, ent_spec in (spec.get("entities") or {}).items():
            role, ordinal = _parse_role_key(key)
            grp = groups.get(role, [])
            if ordinal >= len(grp):
                errors.append(f"matter_device {ref}: no entity for role {key!r}")
                continue
            e = grp[ordinal]
            matched.add(e["entity_id"])
            target_id = ent_spec["id"] if isinstance(ent_spec, dict) else ent_spec
            name = ent_spec.get("name") if isinstance(ent_spec, dict) else None
            hidden = bool(ent_spec.get("hidden")) if isinstance(ent_spec, dict) else False

            cur = e["entity_id"]
            if cur != target_id:
                if target_id in existing_ids:
                    errors.append(f"matter_device {ref}: target {target_id} already exists")
                    continue
                await ha.call({"type": "config/entity_registry/update", "entity_id": cur, "new_entity_id": target_id})
                print(f"matter rename: {cur} -> {target_id}", flush=True)
                existing_ids.discard(cur)
                existing_ids.add(target_id)
                cur = target_id
            await ha.call({
                "type": "config/entity_registry/update",
                "entity_id": cur,
                "area_id": area_id,
                "name": name,
                "hidden_by": "user" if hidden else None,
            })
            print(f"matter update: {cur} -> {area_name} hidden={hidden}" + (f" name={name!r}" if name else ""), flush=True)

        for e in dev_ents:  # STRICT: every entity on a claimed device must be declared
            if e["entity_id"] not in matched:
                errors.append(
                    f"matter_device {ref} ({d.get('name')}): UNCLAIMED entity {e['entity_id']} "
                    f"(role {_uid_role(e.get('unique_id'))!r}) — add it to this device's entities"
                )

    for did, d in matter_devices.items():  # STRICT: every Matter device must be declared
        if did not in claimed_device_ids:
            errors.append(
                f"UNCLAIMED Matter device: {d.get('name')!r} serial={d.get('serial_number')} "
                f"identifiers={d.get('identifiers')} — add a matter_devices block for it"
            )

    if errors:
        for msg in errors:
            print(f"ERROR {msg}", flush=True)
        raise RuntimeError(f"matter_devices reconcile failed: {len(errors)} error(s)")


async def reconcile_unique_id_entities(ha, desired):
    """Canonical entity_id / area / hidden for non-Matter entities matched by stable unique_id
    (e.g. the Daikin renames). No slug renaming, so it can't collide."""
    specs = desired.get("unique_id_entities") or {}
    if not specs:
        return
    area_id_by_name = {a["name"]: a["area_id"] for a in await ha.call({"type": "config/area_registry/list"})}
    ents = await ha.call({"type": "config/entity_registry/list"})
    by_uid = {e.get("unique_id"): e for e in ents}
    existing_ids = {e["entity_id"] for e in ents}
    errors = []
    for uid, spec in specs.items():
        e = by_uid.get(uid)
        if not e:
            errors.append(f"unique_id_entity {uid}: no entity with that unique_id")
            continue
        target_id = spec["id"] if isinstance(spec, dict) else spec
        area_name = spec.get("area") if isinstance(spec, dict) else None
        hidden = spec.get("hidden") if isinstance(spec, dict) else None
        name = spec.get("name") if isinstance(spec, dict) else None
        area_id = area_id_by_name.get(area_name) if area_name else None
        if area_name and area_id is None:
            errors.append(f"unique_id_entity {uid}: area {area_name!r} not found")
            continue
        cur = e["entity_id"]
        if cur != target_id:
            if target_id in existing_ids:
                errors.append(f"unique_id_entity {uid}: target {target_id} already exists")
                continue
            await ha.call({"type": "config/entity_registry/update", "entity_id": cur, "new_entity_id": target_id})
            print(f"uid rename: {cur} -> {target_id}", flush=True)
            existing_ids.discard(cur)
            existing_ids.add(target_id)
            cur = target_id
        update = {"entity_id": cur}
        if area_id is not None:
            update["area_id"] = area_id
        if name is not None:
            update["name"] = name
        if hidden is not None:
            update["hidden_by"] = "user" if hidden else None
        await ha.call({"type": "config/entity_registry/update", **update})
        print(f"uid update: {cur} -> {area_name} hidden={hidden}", flush=True)
    if errors:
        for msg in errors:
            print(f"ERROR {msg}", flush=True)
        raise RuntimeError(f"unique_id_entities reconcile failed: {len(errors)} error(s)")


async def reconcile_static_areas(ha, desired):
    """Area-only assignment for already-canonical entity_ids (templates, Dreame). No rename."""
    mapping = desired.get("static_areas") or {}
    if not mapping:
        return
    area_id_by_name = {a["name"]: a["area_id"] for a in await ha.call({"type": "config/area_registry/list"})}
    existing_ids = {e["entity_id"] for e in await ha.call({"type": "config/entity_registry/list"})}
    errors = []
    for entity_id, area_name in mapping.items():
        if entity_id not in existing_ids:
            errors.append(f"static_area {entity_id}: entity not found")
            continue
        area_id = area_id_by_name.get(area_name)
        if area_id is None:
            errors.append(f"static_area {entity_id}: area {area_name!r} not found")
            continue
        await ha.call({"type": "config/entity_registry/update", "entity_id": entity_id, "area_id": area_id})
        print(f"static area: {entity_id} -> {area_name}", flush=True)
    if errors:
        for msg in errors:
            print(f"ERROR {msg}", flush=True)
        raise RuntimeError(f"static_areas reconcile failed: {len(errors)} error(s)")


async def reconcile_daikin_integration(desired):
    if not (desired.get("daikin") or {}).get("managed"):
        return

    email = os.environ.get("DAIKIN_EMAIL")
    password = os.environ.get("DAIKIN_PASSWORD")
    if not email or not password:
        print("WARN daikin: DAIKIN_EMAIL/DAIKIN_PASSWORD not set", flush=True)
        return

    entries = ha_http("GET", "/api/config/config_entries/entry")
    if any(e.get("domain") == "daikinone" for e in entries):
        print("daikin integration already configured", flush=True)
        return

    print("creating daikin integration...", flush=True)
    flow = ha_http("POST", "/api/config/config_entries/flow", {"handler": "daikinone"})
    flow_id = flow["flow_id"]
    step_id = flow.get("step_id")

    if step_id == "user":
        result = ha_http("POST", f"/api/config/config_entries/flow/{flow_id}", {
            "email": email,
            "password": password,
        })
        if result.get("type") == "create_entry":
            print("daikin integration created", flush=True)
        else:
            print(f"WARN daikin flow unexpected result: {result}", flush=True)
    else:
        print(f"WARN unexpected daikin flow step: {step_id!r}, full response: {flow}", flush=True)


async def reconcile_lovelace_resources(ha, desired):
    resources = desired.get("lovelace_resources") or []
    if not resources:
        return
    existing = await ha.call({"type": "lovelace/resources"})
    by_url = {r["url"]: r for r in existing}
    for res in resources:
        url = res["url"]
        res_type = res.get("type", "module")
        if url in by_url:
            cur = by_url[url]
            if cur.get("type") != res_type:
                await ha.call({
                    "type": "lovelace/resources/update",
                    "resource_id": cur["id"],
                    "url": url,
                    "res_type": res_type,
                })
                print(f"lovelace resource update: {url}", flush=True)
        else:
            await ha.call({
                "type": "lovelace/resources/create",
                "url": url,
                "res_type": res_type,
            })
            print(f"lovelace resource create: {url}", flush=True)


async def reconcile_dreame_vacuum_integration(desired):
    if not (desired.get("dreame_vacuum") or {}).get("managed"):
        return

    username = os.environ.get("DREAME_USERNAME")
    password = os.environ.get("DREAME_PASSWORD")
    country = os.environ.get("DREAME_COUNTRY")
    if not username or not password or not country:
        print("WARN dreame_vacuum: DREAME_USERNAME/DREAME_PASSWORD/DREAME_COUNTRY not set", flush=True)
        return

    entries = ha_http("GET", "/api/config/config_entries/entry")
    if any(e.get("domain") == "dreame_vacuum" for e in entries):
        print("dreame_vacuum integration already configured", flush=True)
        return

    print("creating dreame_vacuum integration...", flush=True)
    flow = ha_http("POST", "/api/config/config_entries/flow", {"handler": "dreame_vacuum"})

    # Walk the multi-step flow (v2.0.0+). Inputs the dreame_vacuum config_flow expects:
    #   user      -> {"configuration_type": "Dreamehome Account"}
    #   dreame    -> {"username", "password", "country"}    (Dreame cloud login)
    #   devices   -> {"devices": "<display key>"}           (skipped when only 1 device)
    #   options   -> {"name", "notify", "color_scheme", "icon_set", "hidden_map_objects"}
    #   donation  -> {"donated": false}
    # The flow can also yield "captcha" or "2fa" steps after login. Those need a human at
    # the HA UI, so we bail with a warning and leave the flow open for the user to finish.
    # NOTE: never log the raw flow response — it contains form defaults that echo back the
    # credentials we just submitted (HA returns last user_input as field defaults).
    prev_step_id = None
    for _ in range(8):
        flow_id = flow.get("flow_id")
        flow_type = flow.get("type")
        step_id = flow.get("step_id")
        errors = flow.get("errors") or {}

        if flow_type == "create_entry":
            print("dreame_vacuum integration created", flush=True)
            return
        if flow_type == "abort":
            print(f"WARN dreame_vacuum flow aborted: {flow.get('reason')}", flush=True)
            return

        # If HA re-rendered the same form with errors, the input was rejected — bail
        # rather than POSTing the same payload again in a loop.
        if errors:
            print(
                f"WARN dreame_vacuum: flow rejected step {step_id!r} with errors {errors}. "
                f"Common causes: wrong Mi credentials, captcha/email-verification required, "
                f"or a 2FA challenge that didn't surface. Try logging into the Mi Home app "
                f"or account.xiaomi.com first to clear any pending verification, then retry. "
                f"If that fails, finish setup once in the HA UI (flow id {flow_id} is open).",
                flush=True,
            )
            return
        if step_id is not None and step_id == prev_step_id:
            print(
                f"WARN dreame_vacuum: flow stuck on step {step_id!r} (no error reported). "
                f"Flow id {flow_id} is open — finish in the HA UI.",
                flush=True,
            )
            return
        prev_step_id = step_id

        if step_id == "user":
            payload = {"configuration_type": "Dreamehome Account"}
        elif step_id == "dreame":
            # Dreame cloud login (separate from Mi cloud). The integration sets prefer_cloud=True
            # internally for Dreame accounts, so we omit it here.
            payload = {
                "username": username,
                "password": password,
                "country": country,
            }
        elif step_id == "mi":
            # Defensive: if the user manually picks Xiaomi Home Account in 1Password's account_type
            # field someday, we still handle it.
            payload = {
                "username": username,
                "password": password,
                "country": country,
                "prefer_cloud": False,
            }
        elif step_id == "devices":
            # HA serializes the schema as [{"name": "devices", "options": [...]}, ...].
            # `options` may be flat strings or [value, label] pairs depending on HA version.
            options = []
            for field in flow.get("data_schema") or []:
                if isinstance(field, dict) and field.get("name") == "devices":
                    for opt in field.get("options") or []:
                        if isinstance(opt, (list, tuple)) and opt:
                            options.append(opt[0])
                        else:
                            options.append(opt)
                    break
            if not options:
                print("WARN dreame_vacuum: device list missing from flow response", flush=True)
                return
            if len(options) > 1:
                print(f"WARN dreame_vacuum: multiple devices found ({options}); picking first", flush=True)
            payload = {"devices": options[0]}
        elif step_id == "options":
            # Defaults mirror the integration's own defaults for non-Mijia models. The user
            # can override via the HA UI's options flow afterwards if they want a different
            # color scheme / icon set.
            payload = {
                "name": "Dreame Vacuum",
                "notify": [],
                "color_scheme": "Dreame Light",
                "icon_set": "Dreame",
                "hidden_map_objects": [],
            }
        elif step_id == "donation":
            payload = {"donated": False}
        elif step_id in ("captcha", "2fa", "reauth_confirm"):
            print(
                f"WARN dreame_vacuum: flow needs interactive {step_id!r} step — finish in the HA UI "
                f"(Settings > Devices > Add integration). Flow id {flow_id} is open.",
                flush=True,
            )
            return
        else:
            print(f"WARN dreame_vacuum: unexpected step {step_id!r} (flow_id {flow_id})", flush=True)
            return

        flow = ha_http("POST", f"/api/config/config_entries/flow/{flow_id}", payload)

    print(f"WARN dreame_vacuum: flow did not complete after 8 steps (last step {prev_step_id!r})", flush=True)


async def reconcile_matter_integration(desired):
    matter_cfg = desired.get("matter") or {}
    server_url = matter_cfg.get("server_url")
    if not server_url:
        return

    entries = ha_http("GET", "/api/config/config_entries/entry")
    if any(e.get("domain") == "matter" for e in entries):
        print("matter integration already configured", flush=True)
        return

    print(f"creating matter integration (url={server_url})...", flush=True)
    flow = ha_http("POST", "/api/config/config_entries/flow", {"handler": "matter"})
    flow_id = flow["flow_id"]
    step_id = flow.get("step_id")

    if step_id == "manual":
        result = ha_http("POST", f"/api/config/config_entries/flow/{flow_id}", {"url": server_url})
        if result.get("type") == "create_entry":
            print("matter integration created", flush=True)
        else:
            print(f"WARN matter flow unexpected result: {result}", flush=True)
    else:
        # On HAOS a different step is presented; log and bail rather than silently failing.
        print(f"WARN unexpected matter flow step: {step_id!r}, full response: {flow}", flush=True)


async def main():
    with open(REGISTRY_PATH) as f:
        desired = yaml.safe_load(f) or {}
    print(
        f"Reconciling: {len(desired.get('floors', []))} floors, "
        f"{len(desired.get('areas', []))} areas, "
        f"{len(desired.get('matter_devices') or [])} matter devices, "
        f"{len(desired.get('unique_id_entities') or {})} unique-id entities, "
        f"{len(desired.get('static_areas') or {})} static areas",
        flush=True,
    )
    ws = await connect_with_retry()
    try:
        ha = HA(ws)
        floors = desired.get("floors", [])
        areas = desired.get("areas", [])
        await reconcile_floors(ha, floors)
        await reconcile_areas(ha, areas)
        if desired.get("prune"):
            await prune(ha, floors, areas)
        await reconcile_matter_devices(ha, desired)
        await reconcile_unique_id_entities(ha, desired)
        await reconcile_static_areas(ha, desired)
        await reconcile_daikin_integration(desired)
        await reconcile_dreame_vacuum_integration(desired)
        await reconcile_matter_integration(desired)
        await reconcile_lovelace_resources(ha, desired)
        print("done", flush=True)
    finally:
        await ws.close()


asyncio.run(main())
