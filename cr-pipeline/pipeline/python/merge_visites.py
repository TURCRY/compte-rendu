import argparse
import json
import re
import unicodedata
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

import pandas as pd


def _clean_text(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, dict):
        for key in ("texte", "resume", "text", "value"):
            if key in value:
                return _clean_text(value.get(key))
        return ""
    if isinstance(value, list):
        return " | ".join([item for item in (_clean_text(v) for v in value) if item])
    if isinstance(value, str):
        return value.strip()
    return str(value).strip()


def _clean_text_list(values: Any) -> list[str]:
    if not values:
        return []
    if isinstance(values, dict):
        text = _clean_text(values)
        return [text] if text else []
    if isinstance(values, list):
        result: list[str] = []
        for item in values:
            text = _clean_text(item)
            if text:
                result.append(text)
        return result
    text = _clean_text(values)
    return [text] if text else []


def _normalize_key(text: str) -> str:
    text = _clean_text(text).lower()
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"[^\w\s]", "", text)
    return text.strip()


def _normalize_search_text(text: Any) -> str:
    value = _normalize_key(_clean_text(text))
    if not value:
        return ""
    normalized = unicodedata.normalize("NFKD", value)
    return "".join(ch for ch in normalized if not unicodedata.combining(ch))


def _parse_date(value: str) -> datetime | None:
    text = _clean_text(value)
    if not text:
        return None
    for fmt in ("%Y-%m-%d", "%d/%m/%Y", "%Y%m%d", "%Y-%m-%d_%H-%M", "%Y-%m-%d %H:%M:%S"):
        try:
            return datetime.strptime(text, fmt)
        except ValueError:
            continue
    return None


def _dedupe_keep_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for value in values:
        key = _normalize_key(value)
        if not key or key in seen:
            continue
        seen.add(key)
        result.append(value)
    return result


def _coerce_avis_participants(value: Any) -> list[dict[str, Any]]:
    if value is None:
        return []
    if isinstance(value, dict):
        return [value]
    if isinstance(value, list):
        result: list[dict[str, Any]] = []
        for item in value:
            if isinstance(item, dict):
                result.append(item)
            else:
                text = _clean_text(item)
                if text:
                    result.append({"nom": "", "role": "", "resume": text})
        return result
    text = _clean_text(value)
    return [{"nom": "", "role": "", "resume": text}] if text else []


def _merge_string_fields(values: list[Any]) -> str:
    texts = [_clean_text(value) for value in values]
    texts = [text for text in texts if text]
    if not texts:
        return ""
    if len(texts) == 1:
        return texts[0]
    return "\n\n".join(_dedupe_keep_order(texts))


def _first_non_empty_text(*values: Any) -> str:
    for value in values:
        text = _clean_text(value)
        if text:
            return text
    return ""


def _first_paragraph(text: Any) -> str:
    value = _clean_text(text)
    if not value:
        return ""
    normalized = value.replace("\r\n", "\n")
    parts = [part.strip() for part in normalized.split("\n\n") if part.strip()]
    if parts:
        return parts[0]
    parts = [part.strip() for part in normalized.split("\n") if part.strip()]
    return parts[0] if parts else value


def _is_consolidable_subject_numero(value: Any) -> bool:
    # Regle metier: le sujet 0 est un residuel hors referentiel et ne doit
    # jamais entrer dans la consolidation experte par sujet.
    numero = _clean_text(value)
    return bool(numero) and numero != "0"


def _normalize_action_dict(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        action = _clean_text(value.get("action"))
        if not action:
            return None
        return {
            "action": action,
            "responsable": _clean_text(value.get("responsable")) or None,
            "echeance": _clean_text(value.get("echeance")) or None,
            "commentaire": _clean_text(value.get("commentaire")),
        }
    text = _clean_text(value)
    if not text:
        return None
    return {"action": text, "responsable": None, "echeance": None, "commentaire": ""}


def _normalize_problem_dict(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        probleme = _clean_text(value.get("probleme"))
        solution = _clean_text(value.get("solution"))
        if not probleme and not solution:
            return None
        return {"probleme": probleme, "solution": solution}
    text = _clean_text(value)
    if not text:
        return None
    return {"probleme": text, "solution": ""}


def _normalize_document_dict(value: Any) -> dict[str, Any] | None:
    if isinstance(value, dict):
        objet = _clean_text(value.get("objet"))
        if not objet:
            return None
        numero = _clean_text(value.get("numero"))
        return {
            "numero": numero or None,
            "objet": objet,
            "demandeur": _clean_text(value.get("demandeur")) or None,
            "destinataire": _clean_text(value.get("destinataire")) or None,
            "echeance": _clean_text(value.get("echeance")) or None,
            "commentaire": _clean_text(value.get("commentaire")),
            "origine": _clean_text(value.get("origine")) or None,
        }
    text = _clean_text(value)
    if not text:
        return None
    return {
        "numero": None,
        "objet": text,
        "demandeur": None,
        "destinataire": None,
        "echeance": None,
        "commentaire": "",
        "origine": None,
    }


def _latest_non_empty(occurrences: list["SujetOccurrence"], field_name: str) -> str:
    for occurrence in reversed(occurrences):
        value = _clean_text(getattr(occurrence, field_name, ""))
        if value:
            return value
    return ""


def _build_subject_fallback_resume(fallback_obj: dict[str, Any]) -> str:
    return _first_paragraph(fallback_obj.get("synthese_echanges"))


POSITION_SIGNAL_MARKERS = [
    "a confirme",
    "ont confirme",
    "a confirme qu",
    "a souligne",
    "ont souligne",
    "a insiste",
    "ont insiste",
    "a indique",
    "ont indique",
    "a precise",
    "ont precise",
    "a releve",
    "ont releve",
    "a mentionne",
    "ont mentionne",
    "a evoque",
    "ont evoque",
    "a demande",
    "ont demande",
    "a exprime",
    "ont exprime",
    "il a ete convenu",
    "a ete convenu",
    "il convient",
    "il est recommande",
    "il apparait necessaire",
    "la necessite de",
    "doit etre",
    "doivent etre",
    "a verifier",
    "a confirmer",
    "absence de",
    "en l'absence",
    "non conforme",
    "non realis",
    "non repris",
    "non leve",
    "manquant",
    "a ete attribue",
    "a ete attribuee",
]

CONTRADICTION_MARKERS = [
    "conteste",
    "contest",
    "desaccord",
    "diverg",
    "s'oppose",
    "s oppose",
    "opposition",
]

CONTRADICTION_NEGATION_MARKERS = [
    "aucun desaccord",
    "pas de desaccord",
    "sans desaccord",
    "sans qu'une contradiction claire ne soit etablie",
    "sans quune contradiction claire ne soit etablie",
    "aucune contradiction",
    "pas de contradiction",
    "procedure contradictoire",
    "sans details precis",
]


def _split_sentences(text: Any) -> list[str]:
    value = _clean_text(text)
    if not value:
        return []
    normalized = value.replace("\r\n", "\n")
    chunks = re.split(r"(?:\n\n+|(?<=[.!?])\s+)", normalized)
    results: list[str] = []
    for chunk in chunks:
        sentence = chunk.strip()
        if sentence:
            results.append(sentence)
    return results


def _extract_actor_markers(occurrence: "SujetOccurrence") -> list[str]:
    markers: list[str] = []
    for item in occurrence.avis_participants:
        nom = _clean_text(item.get("nom"))
        role = _clean_text(item.get("role"))
        for raw in [nom, role]:
            key = _normalize_search_text(raw)
            if not key:
                continue
            if key in {"inconnu", "participant non identifie"}:
                continue
            markers.append(key)
            if "demandeur" in key:
                markers.extend(["demandeurs", "representante des demandeurs", "avocat des demandeurs"])
            if "expert de justice" in key or "expert judiciaire" in key:
                markers.extend(["expert judiciaire", "expert"])
            if "sogep" in key:
                markers.extend(["sogep", "avocat sogep"])
            if "syndic" in key:
                markers.append("syndic")
    return _dedupe_keep_order(markers)


def _sentence_has_explicit_contradiction(sentence: str) -> bool:
    normalized = _normalize_search_text(sentence)
    if not normalized:
        return False
    if any(marker in normalized for marker in CONTRADICTION_NEGATION_MARKERS):
        return False

    negation_prefix_markers = ["aucun", "aucune", "sans", "absence de", "pas de", "ni "]
    for marker in CONTRADICTION_MARKERS:
        idx = normalized.find(marker)
        if idx < 0:
            continue
        prefix = normalized[max(0, idx - 40):idx]
        if any(neg in prefix for neg in negation_prefix_markers):
            continue
        return True
    return False


def _sentence_has_position_signal(sentence: str, actor_markers: list[str]) -> bool:
    normalized = _normalize_search_text(sentence)
    if not normalized:
        return False
    if _sentence_has_explicit_contradiction(sentence):
        return True
    actor_present = any(marker and marker in normalized for marker in actor_markers)
    signal_present = any(marker in normalized for marker in POSITION_SIGNAL_MARKERS)
    consensus_present = any(marker in normalized for marker in ["il a ete convenu", "a ete convenu", "il convient", "il est recommande"])
    return (actor_present and signal_present) or consensus_present


def _extract_position_signals(occurrence: "SujetOccurrence") -> list[str]:
    signals: list[str] = []
    actor_markers = _extract_actor_markers(occurrence)

    for item in occurrence.avis_participants:
        resume = _clean_text(item.get("resume"))
        if not resume:
            continue
        if not _sentence_has_position_signal(resume, actor_markers) and not _sentence_has_explicit_contradiction(resume):
            continue
        identite = " - ".join([part for part in [_clean_text(item.get("nom")), _clean_text(item.get("role"))] if part])
        signals.append(f"{identite}: {resume}" if identite else resume)

    for text_value in [occurrence.synthese_locale, occurrence.conclusion_locale]:
        for sentence in _split_sentences(text_value):
            if _sentence_has_position_signal(sentence, actor_markers):
                signals.append(sentence)

    return _dedupe_keep_order(signals)


def _extract_explicit_contradictions(occurrence: "SujetOccurrence") -> list[dict[str, Any]]:
    contradictions: list[dict[str, Any]] = []
    seen: set[str] = set()

    for text in occurrence.desaccords:
        key = _normalize_key(text)
        if not key or key in seen:
            continue
        contradictions.append({
            "type": "desaccord_explicit",
            "texte": text,
            "visite_id": occurrence.visite_id,
            "date": occurrence.visite_date,
            "source": "desaccords",
        })
        seen.add(key)

    for text_value, source in [
        (occurrence.synthese_locale, "synthese_locale"),
        (occurrence.conclusion_locale, "conclusion_locale"),
    ]:
        for sentence in _split_sentences(text_value):
            key = _normalize_key(sentence)
            if not key or key in seen:
                continue
            if _sentence_has_explicit_contradiction(sentence):
                contradictions.append({
                    "type": "contestation_ou_desaccord_explicit",
                    "texte": sentence,
                    "visite_id": occurrence.visite_id,
                    "date": occurrence.visite_date,
                    "source": source,
                })
                seen.add(key)

    return contradictions


@dataclass
class SujetRef:
    numero: str
    titre: str
    localisation: str = ""
    description_maitre: str = ""
    raw: dict[str, Any] = field(default_factory=dict)


@dataclass
class SujetOccurrence:
    visite_id: str
    visite_date: str
    visite_order: int
    numero: str
    titre: str
    localisation: str
    description: str
    source_dir: str
    source_compact: str | None = None
    source_global_by_sujet: str | None = None
    resume_factuel: str = ""
    points_cles: list[str] = field(default_factory=list)
    actions: list[str] = field(default_factory=list)
    desaccords: list[str] = field(default_factory=list)
    documents_demandes: list[str] = field(default_factory=list)
    elements_techniques: list[str] = field(default_factory=list)
    avis_participants: list[dict[str, Any]] = field(default_factory=list)
    synthese_locale: str = ""
    conclusion_locale: str = ""
    fallback_used: bool = False
    anomalies: list[str] = field(default_factory=list)


@dataclass
class ConsolidatedItem:
    cle: str
    texte: str
    occurrences: list[dict[str, Any]] = field(default_factory=list)
    first_visite_id: str = ""
    last_visite_id: str = ""
    count: int = 0
    statut: str = "observe"


@dataclass
class SujetFusionne:
    referentiel_sujet: dict[str, Any]
    historique_visites: list[dict[str, Any]]
    actions_consolidees: list[dict[str, Any]]
    documents_consolides: list[dict[str, Any]]
    lecture_diachronique: dict[str, Any]
    metadonnees_fusion: dict[str, Any]


def load_subjects_xlsx(path: Path) -> dict[str, SujetRef]:
    df = pd.read_excel(path)
    columns = {str(col).strip().lower(): col for col in df.columns}

    numero_col = columns.get("numero") or columns.get("n°") or columns.get("numéro")
    titre_col = columns.get("titre") or columns.get("intitule") or columns.get("intitulé")
    localisation_col = columns.get("localisation")
    description_col = columns.get("description")

    if not numero_col or not titre_col:
        raise RuntimeError(f"Colonnes minimales non trouvees dans {path}: numero/titre")

    refs: dict[str, SujetRef] = {}
    for _, row in df.iterrows():
        numero = _clean_text(row.get(numero_col))
        if not numero:
            continue
        refs[numero] = SujetRef(
            numero=numero,
            titre=_clean_text(row.get(titre_col)),
            localisation=_clean_text(row.get(localisation_col)) if localisation_col else "",
            description_maitre=_clean_text(row.get(description_col)) if description_col else "",
            raw={str(col): row.get(col) for col in df.columns},
        )
    return refs


def load_manifest(path: Path) -> dict[str, Any]:
    errors: list[str] = []
    data = None
    for encoding in ("utf-8-sig", "utf-8"):
        try:
            with path.open("r", encoding=encoding) as f:
                data = json.load(f)
            break
        except Exception as exc:
            errors.append(f"{encoding}: {exc}")
    if data is None:
        raise RuntimeError(f"Lecture manifeste impossible pour {path}: {' | '.join(errors)}")
    visites = data.get("visites")
    if not isinstance(visites, list) or not visites:
        raise RuntimeError("Le manifeste doit contenir une liste non vide 'visites'.")
    return data


def _load_json(path: Path) -> dict[str, Any]:
    errors: list[str] = []
    for encoding in ("utf-8-sig", "utf-8"):
        try:
            with path.open("r", encoding=encoding) as f:
                return json.load(f)
        except Exception as exc:
            errors.append(f"{encoding}: {exc}")
    raise RuntimeError(f"Lecture JSON impossible pour {path}: {' | '.join(errors)}")


def _find_compact_files(visit_dir: Path) -> list[Path]:
    compact_dir = visit_dir / "pass2E_sujets_compact"
    if not compact_dir.exists():
        return []
    return sorted(compact_dir.glob("*_compact.json"))


def _merge_compact_group(numero: str, paths: list[Path], anomalies: list[str]) -> dict[str, Any]:
    compact_objects = []
    for path in paths:
        try:
            compact_objects.append(_load_json(path))
        except Exception as exc:
            anomalies.append(f"compact unreadable {path}: {exc}")
    if not compact_objects:
        return {}
    if len(paths) > 1:
        anomalies.append(f"numero {numero}: {len(paths)} fichiers compact fusionnes ({', '.join(p.name for p in paths)})")

    merged_lists: dict[str, list[str]] = defaultdict(list)
    stats_chunk_count = 0
    stats_interventions_count = 0
    source_names: list[str] = []
    for obj in compact_objects:
        synthese = obj.get("synthese_intermediaire") or {}
        for key in ["points_cles", "actions", "desaccords", "documents_demandes", "elements_techniques"]:
            merged_lists[key].extend(_clean_text_list(synthese.get(key)))
        merged_lists["resume_factuel"].extend(_clean_text_list(synthese.get("resume_factuel")))
        stats = obj.get("stats") or {}
        try:
            stats_chunk_count += int(stats.get("chunk_count") or 0)
        except Exception:
            anomalies.append(f"numero {numero}: chunk_count non entier dans {obj.get('source_name')}")
        try:
            stats_interventions_count += int(stats.get("interventions_count") or 0)
        except Exception:
            anomalies.append(f"numero {numero}: interventions_count non entier dans {obj.get('source_name')}")
        source_name = _clean_text(obj.get("source_name"))
        if source_name:
            source_names.append(source_name)

    return {
        "source_name": source_names[0] if source_names else f"sujet_{numero}",
        "numero": compact_objects[0].get("numero"),
        "titre": _merge_string_fields([obj.get("titre") for obj in compact_objects]),
        "localisation": _merge_string_fields([obj.get("localisation") for obj in compact_objects]),
        "description": _merge_string_fields([obj.get("description") for obj in compact_objects]),
        "synthese_intermediaire": {
            "resume_factuel": _merge_string_fields(merged_lists["resume_factuel"]),
            "points_cles": _dedupe_keep_order(merged_lists["points_cles"]),
            "actions": _dedupe_keep_order(merged_lists["actions"]),
            "desaccords": _dedupe_keep_order(merged_lists["desaccords"]),
            "documents_demandes": _dedupe_keep_order(merged_lists["documents_demandes"]),
            "elements_techniques": _dedupe_keep_order(merged_lists["elements_techniques"]),
        },
        "stats": {
            "chunk_count": stats_chunk_count,
            "interventions_count": stats_interventions_count,
        },
        "source": {
            "files": [str(path) for path in paths],
            "global_json": compact_objects[0].get("source", {}).get("global_json"),
        },
    }


def _load_compact_subjects(visit_dir: Path, anomalies: list[str]) -> dict[str, dict[str, Any]]:
    grouped_paths: dict[str, list[Path]] = defaultdict(list)
    for compact_path in _find_compact_files(visit_dir):
        try:
            obj = _load_json(compact_path)
        except Exception as exc:
            anomalies.append(f"compact unreadable {compact_path}: {exc}")
            continue
        numero = _clean_text(obj.get("numero"))
        if not numero:
            anomalies.append(f"numero absent dans {compact_path}")
            continue
        grouped_paths[numero].append(compact_path)

    merged: dict[str, dict[str, Any]] = {}
    for numero, paths in grouped_paths.items():
        merged_obj = _merge_compact_group(numero, sorted(paths), anomalies)
        if merged_obj:
            merged[numero] = merged_obj
    return merged


def _merge_fallback_subjects(numero: str, sujets: list[dict[str, Any]], anomalies: list[str], path: Path) -> dict[str, Any]:
    if len(sujets) > 1:
        anomalies.append(f"fallback global_by_sujet: numero {numero} present {len(sujets)} fois dans {path.name}")
    avis_items: list[dict[str, Any]] = []
    for sujet in sujets:
        avis_items.extend(_coerce_avis_participants(sujet.get("avis_participants")))
    return {
        "numero": sujets[0].get("numero"),
        "titre": _merge_string_fields([sujet.get("titre") for sujet in sujets]),
        "localisation": _merge_string_fields([sujet.get("localisation") for sujet in sujets]),
        "description": _merge_string_fields([sujet.get("description") for sujet in sujets]),
        "avis_participants": avis_items,
        "synthese_echanges": _merge_string_fields([sujet.get("synthese_echanges") for sujet in sujets]),
        "conclusion_expert": _merge_string_fields([sujet.get("conclusion_expert") for sujet in sujets]),
        "demandes_documents": _dedupe_keep_order([text for sujet in sujets for text in _clean_text_list(sujet.get("demandes_documents"))]),
    }


def _index_global_by_sujet(path: Path, anomalies: list[str]) -> dict[str, dict[str, Any]]:
    if not path.exists():
        return {}
    try:
        data = _load_json(path)
    except Exception as exc:
        anomalies.append(f"global_by_sujet unreadable {path}: {exc}")
        return {}
    sujets = data.get("sujets", [])
    if not isinstance(sujets, list):
        anomalies.append(f"global_by_sujet mal forme dans {path}: 'sujets' n'est pas une liste")
        return {}
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for sujet in sujets:
        if not isinstance(sujet, dict):
            anomalies.append(f"global_by_sujet item non dict dans {path}")
            continue
        numero = _clean_text(sujet.get("numero"))
        if not numero:
            anomalies.append(f"global_by_sujet sujet sans numero dans {path}")
            continue
        grouped[numero].append(sujet)
    merged: dict[str, dict[str, Any]] = {}
    for numero, items in grouped.items():
        merged[numero] = _merge_fallback_subjects(numero, items, anomalies, path)
    return merged


def normalize_subject(
    sujet_ref: SujetRef | None,
    compact_obj: dict[str, Any] | None,
    fallback_obj: dict[str, Any] | None,
    *,
    visite_id: str,
    visite_date: str,
    visite_order: int,
    source_dir: Path,
    compact_path: Path | None,
    fallback_path: Path | None,
    local_anomalies: list[str],
) -> SujetOccurrence:
    compact_obj = compact_obj or {}
    fallback_obj = fallback_obj or {}
    synthese = compact_obj.get("synthese_intermediaire") or {}
    numero = (
        _clean_text(compact_obj.get("numero"))
        or _clean_text(fallback_obj.get("numero"))
        or (sujet_ref.numero if sujet_ref else "")
    )
    titre = (
        _clean_text(compact_obj.get("titre"))
        or _clean_text(fallback_obj.get("titre"))
        or (sujet_ref.titre if sujet_ref else "")
    )
    localisation = (
        _clean_text(compact_obj.get("localisation"))
        or _clean_text(fallback_obj.get("localisation"))
        or (sujet_ref.localisation if sujet_ref else "")
    )
    description = (
        _clean_text(compact_obj.get("description"))
        or _clean_text(fallback_obj.get("description"))
        or (sujet_ref.description_maitre if sujet_ref else "")
    )

    docs = _clean_text_list(synthese.get("documents_demandes"))
    if not docs:
        docs = _clean_text_list(fallback_obj.get("demandes_documents"))

    resume_factuel = _clean_text(synthese.get("resume_factuel"))
    if not resume_factuel:
        resume_factuel = _build_subject_fallback_resume(fallback_obj)

    return SujetOccurrence(
        visite_id=visite_id,
        visite_date=visite_date,
        visite_order=visite_order,
        numero=numero,
        titre=titre,
        localisation=localisation,
        description=description,
        source_dir=str(source_dir),
        source_compact=str(compact_path) if compact_path else None,
        source_global_by_sujet=str(fallback_path) if fallback_path else None,
        resume_factuel=resume_factuel,
        points_cles=_clean_text_list(synthese.get("points_cles")),
        actions=_clean_text_list(synthese.get("actions")),
        desaccords=_clean_text_list(synthese.get("desaccords")),
        documents_demandes=docs,
        elements_techniques=_clean_text_list(synthese.get("elements_techniques")),
        avis_participants=_coerce_avis_participants(fallback_obj.get("avis_participants")),
        synthese_locale=_clean_text(fallback_obj.get("synthese_echanges")),
        conclusion_locale=_clean_text(fallback_obj.get("conclusion_expert")),
        fallback_used=bool(fallback_obj),
        anomalies=local_anomalies,
    )


def load_visit_subjects(visit_config: dict[str, Any], sujets_ref: dict[str, SujetRef]) -> tuple[list[SujetOccurrence], dict[str, Any]]:
    visite_id = _clean_text(visit_config.get("visite_id"))
    visite_date = _clean_text(visit_config.get("date"))
    visite_order = int(visit_config.get("order") or 0)
    visit_dir = Path(_clean_text(visit_config.get("path")))
    if not visit_dir.exists():
        raise FileNotFoundError(f"Dossier de visite introuvable: {visit_dir}")

    anomalies: list[str] = []
    compact_index = _load_compact_subjects(visit_dir, anomalies)
    global_by_sujet_path = visit_dir / "global_by_sujet.json"
    fallback_index = _index_global_by_sujet(global_by_sujet_path, anomalies)
    occurrences: list[SujetOccurrence] = []
    used_fallback: list[str] = []

    raw_numeros = sorted(set(compact_index.keys()) | set(fallback_index.keys()), key=lambda value: (not value.isdigit(), value))
    sujets_hors_referentiel_exclus = [numero for numero in raw_numeros if not _is_consolidable_subject_numero(numero)]
    if sujets_hors_referentiel_exclus:
        anomalies.append(
            f"{visite_id}: sujets residuels hors referentiel exclus de la consolidation: {', '.join(sujets_hors_referentiel_exclus)}"
        )
    all_numeros = [numero for numero in raw_numeros if _is_consolidable_subject_numero(numero)]
    for numero in all_numeros:
        local_anomalies: list[str] = []
        compact_obj = compact_index.get(numero)
        fallback_obj = fallback_index.get(numero)
        occurrence = normalize_subject(
            sujets_ref.get(numero),
            compact_obj,
            fallback_obj,
            visite_id=visite_id,
            visite_date=visite_date,
            visite_order=visite_order,
            source_dir=visit_dir,
            compact_path=Path(compact_obj.get("source", {}).get("files", [])[0]) if compact_obj and compact_obj.get("source", {}).get("files") else None,
            fallback_path=global_by_sujet_path if global_by_sujet_path.exists() else None,
            local_anomalies=local_anomalies,
        )
        if not occurrence.numero:
            anomalies.append(f"{visite_id}: sujet sans numero resolu")
            continue
        if occurrence.fallback_used:
            used_fallback.append(numero)
        occurrences.append(occurrence)

    if not compact_index and fallback_index:
        anomalies.append(f"{visite_id}: pass2E_sujets_compact absent, fallback global_by_sujet uniquement")
    if not occurrences:
        anomalies.append(f"{visite_id}: aucune occurrence exploitable chargee depuis {visit_dir}")

    global_meeting_path = visit_dir / "global_meeting.json"
    return occurrences, {
        "visite_id": visite_id,
        "date": visite_date,
        "order": visite_order,
        "path": str(visit_dir),
        "global_meeting_path": str(global_meeting_path) if global_meeting_path.exists() else None,
        "compact_count": len(compact_index),
        "fallback_subjects": sorted({numero for numero in used_fallback if _is_consolidable_subject_numero(numero)}),
        "sujets_hors_referentiel_exclus": sujets_hors_referentiel_exclus,
        "anomalies": anomalies,
    }


def merge_actions(occurrences: list[SujetOccurrence]) -> tuple[list[dict[str, Any]], int]:
    grouped: dict[str, ConsolidatedItem] = {}
    duplicate_hits = 0
    for occurrence in occurrences:
        for action in occurrence.actions:
            key = _normalize_key(action)
            if not key:
                continue
            if key in grouped:
                duplicate_hits += 1
            item = grouped.setdefault(
                key,
                ConsolidatedItem(cle=key, texte=action),
            )
            item.occurrences.append(
                {
                    "visite_id": occurrence.visite_id,
                    "date": occurrence.visite_date,
                    "texte": action,
                }
            )

    results: list[dict[str, Any]] = []
    for item in grouped.values():
        item.occurrences.sort(key=lambda x: (x.get("date") or "", x.get("visite_id") or ""))
        item.first_visite_id = item.occurrences[0]["visite_id"]
        item.last_visite_id = item.occurrences[-1]["visite_id"]
        item.count = len(item.occurrences)
        if item.count >= 2:
            item.statut = "reiteree"
        else:
            item.statut = "annoncee"
        results.append(asdict(item))
    results.sort(key=lambda x: (x["first_visite_id"], x["texte"]))
    return results, duplicate_hits


def merge_documents(occurrences: list[SujetOccurrence]) -> tuple[list[dict[str, Any]], int]:
    grouped: dict[str, ConsolidatedItem] = {}
    duplicate_hits = 0
    for occurrence in occurrences:
        for document in occurrence.documents_demandes:
            key = _normalize_key(document)
            if not key:
                continue
            if key in grouped:
                duplicate_hits += 1
            item = grouped.setdefault(
                key,
                ConsolidatedItem(cle=key, texte=document),
            )
            item.occurrences.append(
                {
                    "visite_id": occurrence.visite_id,
                    "date": occurrence.visite_date,
                    "texte": document,
                }
            )

    results: list[dict[str, Any]] = []
    for item in grouped.values():
        item.occurrences.sort(key=lambda x: (x.get("date") or "", x.get("visite_id") or ""))
        item.first_visite_id = item.occurrences[0]["visite_id"]
        item.last_visite_id = item.occurrences[-1]["visite_id"]
        item.count = len(item.occurrences)
        item.statut = "reiteree" if item.count >= 2 else "demandee"
        results.append(asdict(item))
    results.sort(key=lambda x: (x["first_visite_id"], x["texte"]))
    return results, duplicate_hits


def _detect_contradictions(occurrences: list[SujetOccurrence]) -> list[dict[str, Any]]:
    contradictions: list[dict[str, Any]] = []
    seen_keys: set[str] = set()
    for occurrence in occurrences:
        for item in _extract_explicit_contradictions(occurrence):
            key = _normalize_key(item.get("texte"))
            if not key or key in seen_keys:
                continue
            contradictions.append(item)
            seen_keys.add(key)

    return contradictions


def build_lecture_diachronique(
    occurrences: list[SujetOccurrence],
    actions: list[dict[str, Any]],
    documents: list[dict[str, Any]],
) -> dict[str, Any]:
    evolution_constats: list[str] = []
    evolution_positions: list[str] = []
    points_constants_counter: Counter[str] = Counter()

    for occurrence in occurrences:
        if occurrence.resume_factuel:
            evolution_constats.append(
                f"{occurrence.visite_id} ({occurrence.visite_date}) : {occurrence.resume_factuel}"
            )
        for point in occurrence.points_cles:
            norm = _normalize_key(point)
            if norm:
                points_constants_counter[norm] += 1
        position_signals = _extract_position_signals(occurrence)
        if position_signals:
            evolution_positions.append(
                f"{occurrence.visite_id} ({occurrence.visite_date}) : {' | '.join(position_signals[:3])}"
            )

    points_constants = [
        key for key, count in points_constants_counter.items() if key and count >= 2
    ]
    contradictions = _detect_contradictions(occurrences)
    if contradictions:
        etat_avancement = "sujet a contradictions ou evolutions explicites"
    elif len(occurrences) >= 2:
        etat_avancement = "sujet suivi sur plusieurs visites"
    else:
        etat_avancement = "sujet documente sur une seule visite"

    return {
        "evolution_constats": evolution_constats,
        "evolution_positions": evolution_positions,
        "contradictions": contradictions,
        "points_constants": points_constants,
        "actions_ouvertes": [item["texte"] for item in actions if item.get("statut") in {"annoncee", "reiteree"}],
        "documents_encore_demandes": [item["texte"] for item in documents if item.get("statut") in {"demandee", "reiteree"}],
        "etat_avancement": etat_avancement,
    }


def merge_subject(numero: str, sujet_ref: SujetRef | None, occurrences: list[SujetOccurrence]) -> tuple[SujetFusionne, dict[str, Any]]:
    occurrences = sorted(occurrences, key=lambda item: (item.visite_order, item.visite_date, item.visite_id))
    actions, action_duplicates = merge_actions(occurrences)
    documents, document_duplicates = merge_documents(occurrences)
    lecture = build_lecture_diachronique(occurrences, actions, documents)

    referentiel = {
        "numero": numero,
        "titre": sujet_ref.titre if sujet_ref else (occurrences[0].titre if occurrences else ""),
        "localisation": sujet_ref.localisation if sujet_ref else (occurrences[0].localisation if occurrences else ""),
        "description_maitre": sujet_ref.description_maitre if sujet_ref else (occurrences[0].description if occurrences else ""),
    }
    historique_visites = [
        {
            "visite_id": item.visite_id,
            "date": item.visite_date,
            "order": item.visite_order,
            "source": {
                "visit_dir": item.source_dir,
                "pass2e_compact": item.source_compact,
                "global_by_sujet": item.source_global_by_sujet,
                "fallback_used": item.fallback_used,
            },
            "resume_factuel": item.resume_factuel,
            "points_cles": item.points_cles,
            "elements_techniques": item.elements_techniques,
            "desaccords": item.desaccords,
            "documents_demandes": item.documents_demandes,
            "actions": item.actions,
            "avis_participants": item.avis_participants,
            "synthese_locale": item.synthese_locale,
            "conclusion_locale": item.conclusion_locale,
            "anomalies": item.anomalies,
        }
        for item in occurrences
    ]
    metadata = {
        "visites_count": len(occurrences),
        "fallback_used_count": sum(1 for item in occurrences if item.fallback_used),
        "action_duplicate_groups": action_duplicates,
        "document_duplicate_groups": document_duplicates,
        "generated_at": datetime.utcnow().isoformat() + "Z",
    }

    fusion = SujetFusionne(
        referentiel_sujet=referentiel,
        historique_visites=historique_visites,
        actions_consolidees=actions,
        documents_consolides=documents,
        lecture_diachronique=lecture,
        metadonnees_fusion=metadata,
    )

    report = {
        "numero": numero,
        "visites_count": len(occurrences),
        "contradictions_count": len(lecture.get("contradictions", [])),
        "action_duplicate_groups": action_duplicates,
        "document_duplicate_groups": document_duplicates,
        "fallback_used_count": metadata["fallback_used_count"],
        "empty_resume_count": sum(1 for item in occurrences if not item.resume_factuel),
        "empty_conclusion_count": sum(1 for item in occurrences if not item.conclusion_locale),
    }
    return fusion, report


def _build_subject_final_entry(sujet: SujetFusionne) -> dict[str, Any]:
    referentiel = sujet.referentiel_sujet or {}
    historique = sujet.historique_visites or {}
    if isinstance(historique, dict):
        historique = [historique]
    elif not isinstance(historique, list):
        historique = []
    lecture = sujet.lecture_diachronique or {}

    historique_lines: list[str] = []
    for visit in historique:
        if not isinstance(visit, dict):
            continue
        visite_id = _clean_text(visit.get("visite_id"))
        visite_date = _clean_text(visit.get("date"))
        resume = _first_non_empty_text(visit.get("resume_factuel"), visit.get("synthese_locale"))
        if resume:
            historique_lines.append(f"{visite_id} ({visite_date}) : {resume}")

    synthese_parts: list[str] = []
    if historique_lines:
        synthese_parts.append("Historique des visites :\n" + "\n".join(historique_lines))
    if lecture.get("evolution_positions"):
        synthese_parts.append("Evolution des positions :\n" + "\n".join(lecture.get("evolution_positions") or []))
    if lecture.get("documents_encore_demandes"):
        synthese_parts.append(
            "Documents encore attendus :\n" + "\n".join([f"- {item}" for item in lecture.get("documents_encore_demandes") or []])
        )
    if lecture.get("actions_ouvertes"):
        synthese_parts.append(
            "Actions restantes :\n" + "\n".join([f"- {item}" for item in lecture.get("actions_ouvertes") or []])
        )

    conclusion = ""
    for visit in reversed(historique):
        if not isinstance(visit, dict):
            continue
        conclusion = _clean_text(visit.get("conclusion_locale"))
        if conclusion:
            break

    demandes_documents = []
    for item in sujet.documents_consolides or []:
        doc = _normalize_document_dict(
            {
                "numero": referentiel.get("numero"),
                "objet": item.get("texte"),
                "commentaire": f"Occurrences: {item.get('count')}" if item.get("count") else "",
                "origine": "merge_visites",
            }
        )
        if doc:
            demandes_documents.append(doc)

    avis_participants = [
        item
        for visit in historique
        if isinstance(visit, dict)
        for item in (visit.get("avis_participants") or [])
        if isinstance(item, dict)
    ]

    return {
        "numero": referentiel.get("numero"),
        "titre": referentiel.get("titre"),
        "avis_participants": avis_participants,
        "synthese_echanges": "\n\n".join([part for part in synthese_parts if part]),
        "conclusion_expert": conclusion,
        "localisation": referentiel.get("localisation") or "",
        "description": referentiel.get("description_maitre") or "",
        "demandes_documents": demandes_documents,
        "historique_visites": historique,
        "actions_restantes": lecture.get("actions_ouvertes") or [],
        "documents_encore_attendus": lecture.get("documents_encore_demandes") or [],
    }


def _build_final_resume(visit_reports: list[dict[str, Any]], meeting_summary: dict[str, Any], sujets_count: int) -> str:
    lines = [f"Fusion multi-visites par sujet sur {len(visit_reports)} visite(s) et {sujets_count} sujet(s)."]
    for report in visit_reports:
        visite_id = _clean_text(report.get("visite_id"))
        visite_date = _clean_text(report.get("date"))
        lines.append(f"- {visite_id} ({visite_date})")
    meeting_resume = _clean_text(meeting_summary.get("resume_global"))
    if meeting_resume:
        lines.append("")
        lines.append(meeting_resume)
    return "\n".join(lines).strip()


def _build_final_themes(meeting_summary: dict[str, Any]) -> list[dict[str, Any]]:
    themes = []
    if isinstance(meeting_summary.get("themes"), list) and meeting_summary.get("themes"):
        for item in meeting_summary.get("themes") or []:
            if not isinstance(item, dict):
                continue
            themes.append(
                {
                    "titre": _clean_text(item.get("titre")),
                    "synthese": _clean_text_list(item.get("synthese")),
                    "indices_source": _clean_text_list(item.get("timecodes")),
                }
            )
    else:
        for text_value in _clean_text_list(meeting_summary.get("themes_abordes")):
            themes.append({"titre": text_value, "synthese": [], "indices_source": []})
    return [theme for theme in themes if theme.get("titre")]


def _build_final_actions(meeting_summary: dict[str, Any]) -> list[dict[str, Any]]:
    actions = []
    for item in meeting_summary.get("actions") or []:
        normalized = _normalize_action_dict(item)
        if normalized:
            actions.append(normalized)
    return actions


def _build_final_perspectives(meeting_summary: dict[str, Any]) -> list[dict[str, Any]]:
    results = []
    problems = meeting_summary.get("problems") or []
    if problems:
        for item in problems:
            normalized = _normalize_problem_dict(item)
            if normalized:
                results.append(normalized)
    else:
        for item in meeting_summary.get("perspectives") or []:
            normalized = _normalize_problem_dict(item)
            if normalized:
                results.append(normalized)
    return results


def _build_final_demands(meeting_summary: dict[str, Any]) -> list[dict[str, Any]]:
    results = []
    for item in meeting_summary.get("demandes_documents_globales") or []:
        normalized = _normalize_document_dict(item)
        if normalized:
            results.append(normalized)
    return results


def build_global_final_merged(
    merged_subjects: dict[str, SujetFusionne],
    meeting_summary: dict[str, Any],
    visit_reports: list[dict[str, Any]],
    merge_report: dict[str, Any],
) -> dict[str, Any]:
    sujets = [
        _build_subject_final_entry(merged_subjects[numero])
        for numero in sorted(merged_subjects.keys(), key=lambda value: (not value.isdigit(), value))
        if _is_consolidable_subject_numero(numero)
    ]
    visit_dates = [
        _clean_text(report.get("date"))
        for report in visit_reports
        if _clean_text(report.get("date"))
    ]
    final_date = visit_dates[-1] if visit_dates else ""
    return {
        "sujets": sujets,
        "tous_sujets_traites": len(merge_report.get("sujets_absents_referentiel", [])) == 0,
        "sujets_manquants": merge_report.get("sujets_absents_referentiel", []),
        "demandes_documents_globales": _build_final_demands(meeting_summary),
        "date": final_date,
        "link": None,
        "resume": _build_final_resume(visit_reports, meeting_summary, len(sujets)),
        "ordre_du_jour": [],
        "themes_abordes": _build_final_themes(meeting_summary),
        "actions": _build_final_actions(meeting_summary),
        "perspectives": _build_final_perspectives(meeting_summary),
        "annexes": [
            f"Fusion realisee a partir de {len(visit_reports)} visite(s)",
            f"Sujets fusionnes : {len(sujets)}",
        ],
    }


def _safe_filename(numero: str) -> str:
    digits = re.sub(r"\D", "", str(numero))
    return digits.zfill(3) if digits else str(numero).replace(" ", "_")


def export_results(
    output_dir: Path,
    merged_subjects: dict[str, SujetFusionne],
    meeting_summary: dict[str, Any],
    global_final_merged: dict[str, Any],
    merge_report: dict[str, Any],
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    merged_by_sujet_dir = output_dir / "merged_by_sujet"
    merged_by_sujet_dir.mkdir(parents=True, exist_ok=True)

    for numero, sujet in sorted(merged_subjects.items(), key=lambda item: item[0]):
        if not _is_consolidable_subject_numero(numero):
            continue
        sujet_path = merged_by_sujet_dir / f"sujet_{_safe_filename(numero)}.json"
        sujet_path.write_text(
            json.dumps(asdict(sujet), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    global_by_sujet = {
        "sujets": [
            asdict(merged_subjects[numero])
            for numero in sorted(merged_subjects.keys())
            if _is_consolidable_subject_numero(numero)
        ],
        "tous_sujets_traites": len(merge_report.get("sujets_absents_referentiel", [])) == 0,
        "sujets_manquants": merge_report.get("sujets_absents_referentiel", []),
    }
    (output_dir / "global_by_sujet_merged.json").write_text(
        json.dumps(global_by_sujet, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (output_dir / "global_meeting_merged.json").write_text(
        json.dumps(meeting_summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (output_dir / "global_final_merged.json").write_text(
        json.dumps(global_final_merged, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    (output_dir / "merge_report.json").write_text(
        json.dumps(merge_report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def _merge_global_meeting(manifest_visites: list[dict[str, Any]], anomalies: list[str]) -> dict[str, Any]:
    themes: list[dict[str, Any]] = []
    themes_abordes: list[str] = []
    actions: list[dict[str, Any]] = []
    perspectives: list[str] = []
    demandes_documents_globales: list[dict[str, Any]] = []
    problems: list[dict[str, Any]] = []
    resumes: list[str] = []

    for visit in manifest_visites:
        meeting_path = visit.get("global_meeting_path")
        if not meeting_path:
            continue
        try:
            obj = _load_json(Path(meeting_path))
        except Exception as exc:
            anomalies.append(f"global_meeting unreadable {meeting_path}: {exc}")
            continue
        resumes.append(_clean_text(obj.get("resume_global")))
        if isinstance(obj.get("themes"), list):
            themes.extend([item for item in obj.get("themes", []) if isinstance(item, dict)])
        if isinstance(obj.get("themes_abordes"), list):
            themes_abordes.extend(_clean_text_list(obj.get("themes_abordes")))
        if isinstance(obj.get("actions"), list):
            actions.extend([item for item in obj.get("actions", []) if isinstance(item, dict)])
        if isinstance(obj.get("perspectives"), list):
            perspectives.extend(_clean_text_list(obj.get("perspectives")))
        if isinstance(obj.get("demandes_documents_globales"), list):
            demandes_documents_globales.extend([item for item in obj.get("demandes_documents_globales", []) if isinstance(item, dict)])
        if isinstance(obj.get("problems"), list):
            problems.extend([item for item in obj.get("problems", []) if isinstance(item, dict)])

    return {
        "resume_global": _merge_string_fields(resumes) or "Fusion multi-visites a consolider ulterieurement",
        "themes": themes,
        "themes_abordes": _dedupe_keep_order(themes_abordes),
        "actions": actions,
        "perspectives": _dedupe_keep_order(perspectives),
        "demandes_documents_globales": demandes_documents_globales,
        "problems": problems,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Fusion ascendante multi-visites par sujet a partir des pass2E_sujets_compact."
    )
    parser.add_argument("--manifest", required=True, help="Chemin vers le manifeste JSON des visites.")
    parser.add_argument("--sujets-xlsx", required=True, help="Chemin vers le fichier maitre Sujets.xlsx.")
    parser.add_argument("--output-dir", required=True, help="Dossier de sortie des JSON fusionnes.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    manifest_path = Path(args.manifest)
    sujets_xlsx_path = Path(args.sujets_xlsx)
    output_dir = Path(args.output_dir)

    manifest = load_manifest(manifest_path)
    sujets_ref = load_subjects_xlsx(sujets_xlsx_path)

    visit_occurrences: dict[str, list[SujetOccurrence]] = defaultdict(list)
    visit_reports: list[dict[str, Any]] = []
    anomalies: list[str] = []

    visites = manifest["visites"]
    sorted_visites = sorted(
        visites,
        key=lambda item: (
            _parse_date(_clean_text(item.get("date"))) or datetime.max,
            int(item.get("order") or 0),
            _clean_text(item.get("visite_id")),
        ),
    )
    for index, visite in enumerate(sorted_visites, start=1):
        visite.setdefault("order", index)
        try:
            occurrences, report = load_visit_subjects(visite, sujets_ref)
        except Exception as exc:
            visit_reports.append({
                "visite_id": _clean_text(visite.get("visite_id")),
                "date": _clean_text(visite.get("date")),
                "order": int(visite.get("order") or index),
                "path": _clean_text(visite.get("path")),
                "global_meeting_path": None,
                "compact_count": 0,
                "fallback_subjects": [],
                "anomalies": [f"visit load failure: {exc}"],
            })
            anomalies.append(f"visit load failure for {_clean_text(visite.get('visite_id'))}: {exc}")
            continue
        for occurrence in occurrences:
            visit_occurrences[occurrence.numero].append(occurrence)
        visit_reports.append(report)
        anomalies.extend(report.get("anomalies", []))

    merged_subjects: dict[str, SujetFusionne] = {}
    subject_reports: list[dict[str, Any]] = []
    raw_all_numbers = sorted(set(sujets_ref.keys()) | set(visit_occurrences.keys()), key=lambda value: (not value.isdigit(), value))
    sujets_hors_referentiel_exclus = sorted(
        {numero for numero in raw_all_numbers if not _is_consolidable_subject_numero(numero)}
        | {numero for report in visit_reports for numero in report.get("sujets_hors_referentiel_exclus", [])}
    )
    all_numbers = [numero for numero in raw_all_numbers if _is_consolidable_subject_numero(numero)]
    sujets_absents_referentiel = [
        numero
        for numero in sorted(sujets_ref.keys(), key=lambda value: (not value.isdigit(), value))
        if _is_consolidable_subject_numero(numero) and numero not in visit_occurrences
    ]

    for numero in all_numbers:
        occurrences = visit_occurrences.get(numero, [])
        if not occurrences:
            continue
        fusion, subject_report = merge_subject(numero, sujets_ref.get(numero), occurrences)
        merged_subjects[numero] = fusion
        subject_reports.append(subject_report)

    meeting_summary = _merge_global_meeting(visit_reports, anomalies)
    merge_report = {
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "manifest_path": str(manifest_path),
        "sujets_xlsx_path": str(sujets_xlsx_path),
        "visites_traitees": visit_reports,
        "sujets_absents_referentiel": sujets_absents_referentiel,
        "sujets_hors_referentiel_exclus": {
            "regle_metier": "Le sujet 0 est un residuel hors referentiel et ne doit pas figurer dans la consolidation experte par sujet.",
            "numeros": sujets_hors_referentiel_exclus,
            "occurrences_par_visite": [
                {
                    "visite_id": report.get("visite_id"),
                    "numeros": report.get("sujets_hors_referentiel_exclus", []),
                }
                for report in visit_reports
                if report.get("sujets_hors_referentiel_exclus")
            ],
            "total_occurrences_exclues": sum(
                len(report.get("sujets_hors_referentiel_exclus", [])) for report in visit_reports
            ),
        },
        "anomalies": anomalies,
        "conflits_detectes": [
            {
                "numero": report["numero"],
                "contradictions_count": report["contradictions_count"],
            }
            for report in subject_reports
            if report["contradictions_count"] > 0
        ],
        "doublons_regroupes": {
            "actions": sum(report["action_duplicate_groups"] for report in subject_reports),
            "documents": sum(report["document_duplicate_groups"] for report in subject_reports),
        },
        "sujets_fusionnes": subject_reports,
    }

    global_final_merged = build_global_final_merged(merged_subjects, meeting_summary, visit_reports, merge_report)
    export_results(output_dir, merged_subjects, meeting_summary, global_final_merged, merge_report)
    print(f"[merge_visites] Manifeste : {manifest_path}")
    print(f"[merge_visites] Sujets.xlsx : {sujets_xlsx_path}")
    print(f"[merge_visites] Dossier de sortie : {output_dir}")
    print(f"[merge_visites] Sujets fusionnes : {len(merged_subjects)}")
    print(f"[merge_visites] Anomalies : {len(anomalies)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
