#!/usr/bin/env python3
"""Read-only checks for RightMouse SDD documents, traceability and wire examples."""

from __future__ import annotations

import copy
import json
import re
import sys
import unicodedata
from pathlib import Path
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
FEATURE = ROOT / "specs/001-finder-core"
ERRORS: list[str] = []


def require(condition: bool, message: str) -> None:
    if not condition:
        ERRORS.append(message)


def slug(text: str) -> str:
    text = text.strip().lower().replace("`", "")
    text = "".join(
        c for c in text
        if c in "-_ " or not unicodedata.category(c).startswith(("P", "S"))
    )
    return text.replace(" ", "-")


def headings(path: Path) -> list[str]:
    body = re.sub(r"```[^\n]*\n.*?```", "", path.read_text(), flags=re.S)
    return [slug(m.group(1)) for m in re.finditer(r"^#{1,6} (.+)$", body, re.M)]


def check_markdown() -> int:
    docs = sorted((ROOT / "docs/sdd").rglob("*.md")) + sorted(FEATURE.rglob("*.md"))
    for path in docs:
        body = path.read_text()
        display = str(path.relative_to(ROOT))
        require(len(re.findall(r"^# ", body, re.M)) == 1, f"{display}: expected one H1")
        require("## 目录" in body, f"{display}: missing table of contents")
        require("## 参考" in body, f"{display}: missing references")
        fences = re.findall(r"^```(.*)$", body, re.M)
        require(len(fences) % 2 == 0, f"{display}: unclosed fence")
        for lang in fences[::2]:
            require(bool(lang.strip()), f"{display}: untyped fence")
        for target in re.findall(r"\]\(([^\s)]+)\)", body):
            if re.match(r"[a-zA-Z]+:", target):
                continue
            local, _, anchor = unquote(target).partition("#")
            resolved = (path.parent / local).resolve() if local else path
            require(resolved.exists(), f"{display}: broken local link {target}")
            if anchor and resolved.exists() and resolved.suffix == ".md":
                require(anchor in headings(resolved), f"{display}: broken anchor {target}")
    return len(docs)


def check_traceability() -> tuple[int, int, int]:
    manifest = json.loads((FEATURE / "traceability.json").read_text())
    spec = (FEATURE / "spec.md").read_text()
    task_text = (FEATURE / "tasks.md").read_text()
    cases_text = (FEATURE / "checklists/acceptance.md").read_text()
    reqs = {r["id"]: r for r in manifest["requirements"]}
    tasks = {t["id"]: t for t in manifest["tasks"]}
    cases = {c["id"]: c for c in manifest["cases"]}
    for name, items in [("requirements", reqs), ("tasks", tasks), ("cases", cases)]:
        require(len(items) == len(manifest[name]), f"Duplicate ID in {name}")
    spec_ids = set(re.findall(r"^\| ((?:N?FR)-\d{3}) \|", spec, re.M))
    task_ids = set(re.findall(r"^- \[[ x]\] \*\*(T\d{3}) ", task_text, re.M))
    case_ids = set(re.findall(r"^\| (AC-\d{3}) \|", cases_text, re.M))
    require(spec_ids == set(reqs), "Requirement IDs differ between spec and manifest")
    require(task_ids == set(tasks), "Task IDs differ between Markdown and manifest")
    require(case_ids == set(cases), "Case IDs differ between Markdown and manifest")
    covered_cases: set[str] = set()
    for rid, row in reqs.items():
        require(bool(row["tasks"]) and bool(row["cases"]), f"{rid}: incomplete mapping")
        require(set(row["tasks"]) <= set(tasks), f"{rid}: unknown tasks")
        require(set(row["cases"]) <= set(cases), f"{rid}: unknown cases")
        covered_cases.update(row["cases"])
        line = re.search(rf"^\| {rid} \|(.+)$", cases_text, re.M)
        require(line is not None, f"{rid}: missing readable mapping")
        if line:
            require(set(re.findall(r"T\d{3}", line.group(1))) == set(row["tasks"]), f"{rid}: task mapping drift")
            require(set(re.findall(r"AC-\d{3}", line.group(1))) == set(row["cases"]), f"{rid}: case mapping drift")
    require(covered_cases == set(cases), "Unmapped acceptance cases")
    for tid, row in tasks.items():
        require(set(row["dependsOn"]) <= set(tasks), f"{tid}: unknown dependency")
        line = re.search(rf"^- \[([ x])\] \*\*{tid} .+?依赖：([^。]+)。", task_text, re.M)
        require(line is not None, f"{tid}: missing task/dependency declaration")
        if line:
            require(set(re.findall(r"T\d{3}", line.group(2))) == set(row["dependsOn"]), f"{tid}: dependency drift")
            require((line.group(1) == "x") == (row["status"] == "completed"), f"{tid}: completion status drift")
        if row["status"] == "completed":
            require(bool(row["evidence"]), f"{tid}: completed without evidence")
    for cid, row in cases.items():
        if row["status"] == "PASS":
            require(bool(row["evidence"]), f"{cid}: PASS without evidence")
        if row["status"] == "NOT_RUN" and row["evidence"]:
            require(bool(row.get("remaining", "").strip()), f"{cid}: partial evidence without remaining scope")
    for row in [*tasks.values(), *cases.values()]:
        for evidence in row["evidence"]:
            path = (FEATURE / evidence).resolve()
            require(path.is_relative_to(ROOT) and path.is_file(), f"{row['id']}: invalid evidence path {evidence}")
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(tid: str) -> None:
        if tid in visiting:
            ERRORS.append(f"Dependency cycle at {tid}")
            return
        if tid in visited or tid not in tasks:
            return
        visiting.add(tid)
        for dependency in tasks[tid]["dependsOn"]:
            visit(dependency)
        visiting.remove(tid)
        visited.add(tid)

    for tid in tasks:
        visit(tid)
    return len(reqs), len(tasks), len(cases)


def check_schemas() -> int:
    try:
        from jsonschema import Draft202012Validator, FormatChecker
    except ImportError:
        ERRORS.append("Missing jsonschema: install tools/requirements-docs.txt in a virtual environment")
        return 0
    contracts = FEATURE / "contracts"
    validators = {}
    for kind in ("request", "response", "menu-snapshot"):
        schema = json.loads((contracts / f"{kind}.schema.json").read_text())
        Draft202012Validator.check_schema(schema)
        validators[kind] = Draft202012Validator(schema, format_checker=FormatChecker())
    examples = [
        ("create-file.json", "request", True),
        ("transfer.json", "request", True),
        ("invalid-command.json", "request", False),
        ("accepted.json", "response", True),
        ("partial.json", "response", True),
    ]
    count = 0
    for name, kind, expected in examples:
        value = json.loads((contracts / "examples" / name).read_text())
        actual = validators[kind].is_valid(value)
        require(actual == expected, f"{name}: expected schema validity {expected}, got {actual}")
        count += 1
    # These probes test the document's schemas, not the unimplemented app receiver.
    valid = json.loads((contracts / "examples/create-file.json").read_text())
    destination = valid["action"]["destination"]
    actions = [
        {"type": "copyText", "format": "shellPath"},
        {"type": "stageMove"},
        {"type": "pasteMove", "pendingToken": valid["requestID"], "destination": destination, "conflictPolicy": "keepBoth"},
        {"type": "openFavorite", "favoriteID": valid["requestID"]},
        {"type": "openWith", "integrationID": "builtin.terminal", "mode": "directory"},
    ]
    for action in actions:
        probe = copy.deepcopy(valid)
        probe["action"] = action
        require(validators["request"].is_valid(probe), f"Valid action schema rejected: {action['type']}")
        count += 1
    negative = []
    for key, value in [("schemaVersion", 2), ("requestID", "not-a-uuid"), ("createdAt", "not-a-date"), ("extra", True)]:
        probe = copy.deepcopy(valid)
        probe[key] = value
        negative.append(probe)
    probe = copy.deepcopy(valid)
    probe["action"]["destination"]["fileURL"] = "https://example.com/"
    negative.append(probe)
    probe = copy.deepcopy(valid)
    probe["context"]["selection"] = [destination] * 1025
    negative.append(probe)
    probe = copy.deepcopy(valid)
    del probe["action"]["destination"]
    negative.append(probe)
    for index, probe in enumerate(negative):
        require(not validators["request"].is_valid(probe), f"Negative schema probe {index} unexpectedly accepted")
        count += 1
    menu = {"schemaVersion": 1, "revision": 0, "available": True, "compactMenu": False,
            "conflictPolicy": "skip", "actions": [], "favorites": [], "watchedLocations": [],
            "recentDestinations": [], "integrations": [], "templates": [{"id": "txt", "name": "文本"}]}
    require(validators["menu-snapshot"].is_valid(menu), "Minimal menu snapshot rejected")
    count += 1
    invalid_menus = []
    future = copy.deepcopy(menu)
    future["schemaVersion"] = 2
    invalid_menus.append(future)
    template_body = copy.deepcopy(menu)
    template_body["templates"][0]["body"] = "private content"
    invalid_menus.append(template_body)
    location = {"id": valid["requestID"], "name": "目标", "path": "/fixture", "order": 0}
    bookmark = copy.deepcopy(menu)
    bookmark["favorites"] = [dict(location, bookmarkData="private grant")]
    invalid_menus.append(bookmark)
    oversized = copy.deepcopy(menu)
    oversized["recentDestinations"] = [location] * 11
    invalid_menus.append(oversized)
    for index, probe in enumerate(invalid_menus):
        require(not validators["menu-snapshot"].is_valid(probe), f"Unsafe menu snapshot probe {index} accepted")
        count += 1
    return count


def main() -> int:
    docs = check_markdown()
    requirements, tasks, cases = check_traceability()
    probes = check_schemas()
    if ERRORS:
        for error in ERRORS:
            print(f"ERROR: {error}")
        return 1
    print(f"PASS: {docs} Markdown documents; local links and anchors valid")
    print(f"PASS: {requirements} requirements -> {tasks} tasks -> {cases} acceptance cases; acyclic dependencies")
    print(f"PASS: 3 JSON Schemas; {probes} positive/negative document probes")
    print("Application tests: NOT_RUN; document validation is not product acceptance")
    return 0


if __name__ == "__main__":
    sys.exit(main())
