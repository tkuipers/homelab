#!/usr/bin/env python3
import asyncio
import json
import os
import sys
import yaml
import websockets

HA_URL = os.environ["HA_URL"]
HA_TOKEN = os.environ["HA_TOKEN"]
REGISTRY_PATH = os.environ.get("REGISTRY_PATH", "/registry/registry.yaml")


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


async def reconcile_entities(ha, desired):
    if not desired:
        return
    area_id_by_name = {a["name"]: a["area_id"] for a in await ha.call({"type": "config/area_registry/list"})}
    for entity_id, area_name in desired.items():
        target_area_id = area_id_by_name.get(area_name)
        if not target_area_id:
            print(f"WARN entity {entity_id}: area {area_name!r} not found", flush=True)
            continue
        try:
            await ha.call({"type": "config/entity_registry/update", "entity_id": entity_id, "area_id": target_area_id})
            print(f"entity assign: {entity_id} -> {area_name}", flush=True)
        except RuntimeError as e:
            print(f"WARN entity {entity_id}: {e}", flush=True)


async def main():
    with open(REGISTRY_PATH) as f:
        desired = yaml.safe_load(f) or {}
    print(
        f"Reconciling: {len(desired.get('floors', []))} floors, "
        f"{len(desired.get('areas', []))} areas, "
        f"{len(desired.get('entities') or {})} entity assignments",
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
        await reconcile_entities(ha, desired.get("entities") or {})
        print("done", flush=True)
    finally:
        await ws.close()


asyncio.run(main())
