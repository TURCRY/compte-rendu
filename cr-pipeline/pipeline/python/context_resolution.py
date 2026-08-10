import argparse
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any


CONTEXT_FIELDS = ("mission", "system", "user", "etat_avancement")
FALLBACK_CONTEXT_FILENAME = "contexte_general_compte_rendu.from_infos_projet.json"


@dataclass(frozen=True)
class ResolvedContext:
    path: Path
    source: str
    reason: str
    context: dict[str, Any]


def _read_json_object(path: Path) -> tuple[dict[str, Any] | None, str]:
    try:
        with path.open("r", encoding="utf-8-sig") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return None, "absent"
    except OSError as exc:
        return None, f"unreadable: {exc}"
    except json.JSONDecodeError as exc:
        return None, f"invalid_json: line {exc.lineno}, column {exc.colno}: {exc.msg}"
    if not isinstance(data, dict):
        return None, "invalid_root: expected object"
    return data, "ok"


def context_has_recognized_value(data: dict[str, Any]) -> bool:
    for field in CONTEXT_FIELDS:
        value = data.get(field)
        if value is not None and str(value).strip():
            return True
    return False


def _valid_context_file(path: Path) -> tuple[dict[str, Any] | None, str]:
    data, reason = _read_json_object(path)
    if data is None:
        return None, reason
    if not context_has_recognized_value(data):
        return None, "empty_context: no recognized context field"
    return data, "ok"


def _context_from_infos(infos: dict[str, Any]) -> dict[str, str]:
    context: dict[str, str] = {}
    for field in CONTEXT_FIELDS:
        value = infos.get(field)
        context[field] = "" if value is None else str(value)
    return context


def materialize_context(path: Path, context: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with tmp_path.open("w", encoding="utf-8") as handle:
            json.dump(context, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(tmp_path, path)
    except Exception:
        try:
            tmp_path.unlink()
        except OSError:
            pass
        raise


def resolve_compte_rendu_context(
    *,
    infos_path: Path,
    csv_path: Path,
    materialize_dir: Path | None = None,
) -> ResolvedContext:
    infos, infos_reason = _read_json_object(infos_path)
    if infos is None:
        raise RuntimeError(f"infos_projet.json invalide: {infos_path} ({infos_reason})")

    csv_dir = csv_path if csv_path.is_dir() else csv_path.parent
    candidates = (
        ("contexte_general_compte_rendu.json", csv_dir / "contexte_general_compte_rendu.json"),
        ("contexte_general.json", csv_dir / "contexte_general.json"),
    )
    rejected: list[str] = []
    for source, path in candidates:
        context, reason = _valid_context_file(path)
        if context is not None:
            return ResolvedContext(path=path, source=source, reason="valid", context=context)
        rejected.append(f"{source}: {reason}")

    fallback_context = _context_from_infos(infos)
    if context_has_recognized_value(fallback_context):
        out_dir = materialize_dir or csv_dir
        fallback_path = out_dir / FALLBACK_CONTEXT_FILENAME
        materialize_context(fallback_path, fallback_context)
        return ResolvedContext(
            path=fallback_path,
            source="infos_projet.json",
            reason="; ".join(rejected) or "no context file",
            context=fallback_context,
        )

    raise RuntimeError(
        "Aucun contexte compte-rendu exploitable: "
        + "; ".join(rejected + ["infos_projet.json: no recognized context field"])
    )


def _build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Resout le contexte compte-rendu canonique.")
    parser.add_argument("--infos", required=True, help="Chemin vers infos_projet.json.")
    parser.add_argument("--csv", required=True, help="Chemin vers le CSV ou son dossier.")
    parser.add_argument("--materialize-dir", default="", help="Dossier ou ecrire le fallback issu d'infos_projet.json.")
    parser.add_argument("--shell", action="store_true", help="Imprime des affectations shell simples.")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_arg_parser().parse_args(argv)
    resolved = resolve_compte_rendu_context(
        infos_path=Path(args.infos),
        csv_path=Path(args.csv),
        materialize_dir=Path(args.materialize_dir) if args.materialize_dir else None,
    )
    payload = {
        "path": str(resolved.path),
        "source": resolved.source,
        "reason": resolved.reason,
    }
    if args.shell:
        for key, value in payload.items():
            print(f"context_{key}={value}")
    else:
        print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
