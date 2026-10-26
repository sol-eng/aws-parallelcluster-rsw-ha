"""Raise uv constraint floors for vulnerable locked packages.

Audits a uv project's lockfile with pip-audit, adds or raises a
"pkg>=fixed" entry in [tool.uv] constraint-dependencies for every
vulnerable transitive dependency, then relocks and re-exports
requirements.txt. Prints a markdown summary of what changed.

Usage: security_floors.py <project-dir>
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

import tomlkit
from packaging.requirements import Requirement
from packaging.utils import canonicalize_name
from packaging.version import Version


def run(cmd, cwd, check=True):
    return subprocess.run(cmd, cwd=cwd, check=check, capture_output=True, text=True)


def audit(project):
    with tempfile.TemporaryDirectory() as tmp:
        reqs = Path(tmp) / "requirements.txt"
        run(["uv", "export", "--frozen", "--no-hashes", "--no-emit-project",
             "-o", str(reqs)], project)
        # exits 1 when vulnerabilities are found, so check the output instead
        out = run(["uvx", "pip-audit", "-r", str(reqs), "--no-deps",
                   "--disable-pip", "-f", "json"], project, check=False)
    try:
        return json.loads(out.stdout)["dependencies"]
    except json.JSONDecodeError:
        sys.exit(f"pip-audit failed:\n{out.stderr}")


def main(project):
    project = Path(project)
    pyproject = project / "pyproject.toml"
    doc = tomlkit.parse(pyproject.read_text())
    uv = doc["tool"]["uv"]
    direct = {canonicalize_name(Requirement(r).name)
              for r in doc["project"]["dependencies"]}
    floors = {canonicalize_name(Requirement(c).name): str(c)
              for c in uv.get("constraint-dependencies", [])}

    raised, manual = [], []
    for dep in audit(project):
        if not dep.get("vulns"):
            continue
        name, current = canonicalize_name(dep["name"]), Version(dep["version"])
        fixes, unfixed = [], []
        for vuln in dep["vulns"]:
            # lowest fix above the locked version, i.e. on the same release line
            newer = [Version(f) for f in vuln["fix_versions"] if Version(f) > current]
            (fixes.append(min(newer)) if newer else unfixed.append(vuln["id"]))
        ids = ", ".join(v["id"] for v in dep["vulns"])
        if name in direct:
            manual.append(f"`{name}` {current} is a direct dependency ({ids}); bump its pin")
            continue
        if unfixed:
            manual.append(f"`{name}` {current} has no fixed release for {', '.join(unfixed)}")
        if fixes:
            floors[name] = f"{name}>={max(fixes)}"
            raised.append((name, current, max(fixes), ids))

    if not raised and not manual:
        return
    if raised:
        constraints = tomlkit.array()
        constraints.extend(sorted(floors.values()))
        uv["constraint-dependencies"] = constraints.multiline(True)
        pyproject.write_text(tomlkit.dumps(doc))
        upgrades = [arg for name, *_ in raised for arg in ("--upgrade-package", name)]
        run(["uv", "lock", *upgrades], project)
        run(["uv", "export", "--no-hashes", "-o", "requirements.txt"], project)

    print(f"### `{project}`\n")
    if raised:
        print("| Package | Locked | New floor | Advisories |\n|---|---|---|---|")
        for name, current, floor, ids in raised:
            print(f"| {name} | {current} | >={floor} | {ids} |")
        print()
    if manual:
        print("Needs manual attention:\n")
        print("\n".join(f"- {m}" for m in manual) + "\n")


if __name__ == "__main__":
    main(sys.argv[1])
